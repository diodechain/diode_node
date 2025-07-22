defmodule Cron do
  use GenServer
  require Logger

  defmodule Job do
    defstruct name: nil, interval: nil, fun: nil, startup: true
  end

  def start_link(_args) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    jobs = [
      %Job{name: "Broadcast Self", interval: :timer.minutes(5), fun: &Diode.broadcast_self/0},
      %Job{name: "Reload Cert", interval: :timer.hours(24), fun: &Diode.maybe_import_key/0},
      %Job{
        name: "Connectivity",
        interval: :timer.hours(1),
        fun: &Connectivity.check_connectivity/0
      },
      %Job{
        name: "Submit tickets",
        interval: :timer.hours(1),
        fun: &TicketStore.maybe_submit_tickets/0,
        startup: false
      },
      %Job{name: "Memory report", interval: :timer.hours(1), fun: &Memory.report/0},
      %Job{name: "Memory check", interval: :timer.minutes(10), fun: &Memory.check_rss/0},
      %Job{
        name: "Clear invalid objects",
        interval: :timer.hours(24),
        fun: &Model.KademliaSql.clear_invalid_objects/0
      },
      %Job{
        name: "Cleanup LRU cache",
        interval: :timer.hours(1),
        fun: fn ->
          created_at = Exqlite.LRU.created_at(Exqlite.LRU)

          if Exqlite.LRU.now() - created_at > :timer.hours(24) * 7 do
            Exqlite.LRU.flush(Exqlite.LRU)
          else
            Exqlite.LRU.gc(Exqlite.LRU)
          end

          Exqlite.LRU.gc(Network.Stats.LRU)
        end
      },
      %Job{
        name: "Update chain list",
        interval: :timer.hours(1),
        fun: &RemoteChain.ChainList.update/0
      }
    ]

    for job <- jobs do
      :timer.send_interval(job.interval, self(), {:execute, job.name, job.fun})

      if job.startup do
        send(self(), {:execute, job.name, job.fun})
      end
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info({:execute, name, fun}, state) do
    Debouncer.immediate({__MODULE__, name}, fn ->
      Logger.info("Cron: Executing #{name}...")

      OnCrash.call(fn reason ->
        if reason != :normal do
          Logger.error("Cron: #{name} crashed: #{inspect(reason)}")
        end
      end)

      Process.register(self(), String.to_atom("#{name}"))
      fun.()
    end)

    {:noreply, state}
  end
end
