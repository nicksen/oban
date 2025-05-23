defmodule Oban.Plugins.Reindexer do
  @moduledoc """
  Periodically rebuild indexes to minimize database bloat.

  Over time various Oban indexes may grow without `VACUUM` cleaning them up properly. When this
  happens, rebuilding the indexes will release bloat.

  The plugin uses `REINDEX` with the `CONCURRENTLY` option to rebuild without taking any locks
  that prevent concurrent inserts, updates, or deletes on the table.

  Note: This plugin requires the `CONCURRENTLY` option, which is only available in Postgres 12 and
  above.

  ## Using the Plugin

  By default, the plugin will reindex once a day, at midnight UTC:

      config :my_app, Oban,
        plugins: [Oban.Plugins.Reindexer],
        ...

  To run on a different schedule you can provide a cron expression. For example, you could use the
  `"@weekly"` shorthand to run once a week on Sunday:

      config :my_app, Oban,
        plugins: [{Oban.Plugins.Reindexer, schedule: "@weekly"}],
        ...

  ## Options

    * `:indexes` — a list of indexes to reindex on the `oban_jobs` table. Defaults to only the
      `oban_jobs_args_index` and `oban_jobs_meta_index`.

    * `:schedule` — a cron expression that controls when to reindex. Defaults to `"@midnight"`.

    * `:timeout` - time in milliseconds to wait for each query call to finish. Defaults to 15 seconds.

    * `:timezone` — which timezone to use when evaluating the schedule. To use a timezone other than
      the default of "Etc/UTC" you *must* have a timezone database like [tz][tz] installed and
      configured.

  [tz]: https://hexdocs.pm/tz
  """

  @behaviour Oban.Plugin

  use GenServer

  alias Oban.{Cron, Peer, Plugin, Repo, Validation}
  alias __MODULE__, as: State

  require Logger

  @type option ::
          Plugin.option()
          | {:indexes, [String.t()]}
          | {:schedule, String.t()}
          | {:timezone, Calendar.time_zone()}
          | {:timeout, timeout()}

  defstruct [
    :conf,
    indexes: ~w(oban_jobs_args_index oban_jobs_meta_index),
    schedule: "@midnight",
    timeout: :timer.seconds(15),
    timezone: "Etc/UTC"
  ]

  @doc false
  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts), do: super(opts)

  @impl Plugin
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)

    GenServer.start_link(__MODULE__, struct!(State, opts), name: name)
  end

  @impl Plugin
  def validate(opts) do
    Validation.validate_schema(opts,
      conf: :ok,
      name: :ok,
      indexes: {:list, :string},
      schedule: :schedule,
      timeout: :timeout,
      timezone: :timezone
    )
  end

  @impl Plugin
  def format_logger_output(_conf, _meta), do: %{}

  @impl GenServer
  def init(state) do
    Process.flag(:trap_exit, true)

    :telemetry.execute([:oban, :plugin, :init], %{}, %{conf: state.conf, plugin: __MODULE__})

    Cron.schedule_interval(self(), :reindex, state.schedule, state.timezone)

    {:ok, state}
  end

  @impl GenServer
  def handle_info(:reindex, %State{} = state) do
    meta = %{conf: state.conf, plugin: __MODULE__}

    :telemetry.span([:oban, :plugin], meta, fn ->
      case check_leadership_and_reindex(state) do
        :ok ->
          {:ok, meta}

        error ->
          {:error, Map.put(meta, :error, error)}
      end
    end)

    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.warning(
      message: "Received unexpected message: #{inspect(message)}",
      source: :oban,
      module: __MODULE__
    )

    {:noreply, state}
  end

  # Reindexing

  defp check_leadership_and_reindex(state) do
    if Peer.leader?(state.conf) do
      queries = [deindex_query(state) | Enum.map(state.indexes, &reindex_query(state, &1))]

      Enum.reduce_while(queries, :ok, fn query, _ ->
        case Repo.query(state.conf, query, [], timeout: state.timeout) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp reindex_query(state, index) do
    prefix = inspect(state.conf.prefix)

    "REINDEX INDEX CONCURRENTLY #{prefix}.#{index}"
  end

  defp deindex_query(state) do
    """
    DO $$
    DECLARE
      rec record;
    BEGIN
      FOR rec IN
        SELECT relname, relnamespace::regnamespace AS namespace
        FROM pg_index i
        JOIN pg_class c on c.oid = i.indexrelid
        WHERE relnamespace = '#{state.conf.prefix}'::regnamespace
          AND NOT indisvalid
          AND starts_with(relname, 'oban_jobs')
      LOOP
        EXECUTE format('DROP INDEX CONCURRENTLY %s.%s', rec.namespace, rec.relname);
      END LOOP;
    END $$
    """
  end
end
