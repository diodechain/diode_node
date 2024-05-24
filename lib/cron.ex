defmodule Cron do
  use GenServer
  require Logger

  def start_link do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    jobs = [
      {"Reload Cert", 24 * 60 * 60, &Diode.maybe_import_key/0}
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
