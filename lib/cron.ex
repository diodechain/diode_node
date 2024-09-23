defmodule Cron do
  use GenServer
  require Logger

  def start_link(_args) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    jobs = [
      {"Broadcast Self", 5 * 60, &Diode.broadcast_self/0},
      {"Reload Cert", 24 * 60 * 60, &Diode.maybe_import_key/0},
      {"Check connectivity", 1 * 60 * 60, &Connectivity.check_connectivity/0}
    ]

    for {name, seconds, fun} <- jobs do
      :timer.send_interval(seconds * 1000, self(), {:execute, name, fun})
      send(self(), {:execute, name, fun})
    end

    {:ok, %{}}
  end

  def handle_info({:execute, name, fun}, state) do
    Debouncer.immediate({__MODULE__, name}, fn ->
      Logger.info("Cron: Executing #{name}...")
      fun.()
    end)

    {:noreply, state}
  end
end
