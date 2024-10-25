# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.Channel do
  use GenServer
  require Logger
  import DiodeClient.Object.Channel
  alias DiodeClient.Base16
  alias Network.PortCollection

  def start_link(ch = channel()) do
    GenServer.start_link(__MODULE__, ch, hibernate_after: 5_000)
  end

  def init(ch) do
    state = %{
      ports: %PortCollection{pid: self()},
      pid: self(),
      channel: ch
    }

    {:ok, state}
  end

  def handle_info(msg, state) do
    case PortCollection.maybe_handle_info(msg, state.ports) do
      ports = %PortCollection{} ->
        {:noreply, %{state | ports: ports}}

      false ->
        Logger.warning("Channel: Unhandled info #{inspect(msg)}")
        {:noreply, state}
    end
  end

  def handle_cast({:pccb_portopen, port, _device_address}, state) do
    case PortCollection.confirm_portopen(state.ports, port.ref) do
      {:ok, ports} ->
        {:noreply, %{state | ports: ports}}

      {:error, reason} ->
        Logger.error(
          "Channel: ignoring response for #{inspect(reason)} from #{Base16.encode(port.ref)}"
        )

        {:noreply, state}
    end
  end

  def handle_cast({:pccb_portsend, port, data}, state) do
    for {ref, _port} <- state.ports.refs do
      if ref != port.ref do
        PortCollection.portsend(state.ports, ref, data)
      end
    end

    {:noreply, state}
  end

  def handle_cast({:pccb_portclose, _port}, state) do
    {:noreply, state}
  end
end
