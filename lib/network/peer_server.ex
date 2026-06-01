# Diode Server
# Copyright 2021-2025 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.PeerServer do
  @moduledoc """
  TLS connection registry for Kademlia peer (v2) handlers.

  Duplicate registrations **reject** the new connection (`:kill_clone`) or replace
  the stale peer when `connect_key` is nil or matches the slot key.
  """

  use GenServer

  use Network.Common,
    server: [
      handler: Network.PeerHandlerV2,
      name: Network.PeerHandlerV2,
      conflict: :peer,
      ready_ets: true
    ]

  alias Network.Common
  alias DiodeClient.Wallet

  defstruct sockets: %{},
            clients: %{},
            ready: %{},
            ports: [],
            opts: %{},
            pid: nil,
            acceptors: %{},
            self_conns: []

  def get_ready_connections(name \\ @name) do
    if Process.whereis(name), do: Network.PeerReadyEts.read(), else: %{}
  end

  def ensure_node_connection(node_id, address, port, name \\ @name)
      when node_id == nil or is_tuple(node_id) do
    GenServerDbg.call(name, {:ensure_node_connection, node_id, address, port})
  end

  def handle_call({:ensure_node_connection, node_id, address, port}, _from, state)
      when node_id == nil or is_tuple(node_id) do
    if Wallet.equal?(Diode.wallet(), node_id) do
      client = Enum.find(state.self_conns, &Process.alive?/1)

      if client != nil do
        {:reply, client, state}
      else
        worker =
          Common.start_worker!(state, @handler, [
            :connect,
            node_id,
            "localhost",
            Diode.peer2_port()
          ])

        {:reply, worker, %{state | self_conns: [worker]}}
      end
    else
      key = Common.to_key(node_id)

      case Common.lookup_client_pid(state.clients, key) do
        pid when is_pid(pid) ->
          {:reply, pid, state}

        nil ->
          worker = Common.start_worker!(state, @handler, [:connect, node_id, address, port])

          clients =
            state.clients
            |> Map.put(key, Common.client_entry(worker, address, port))
            |> Map.put(worker, key)

          {:reply, worker, %{state | clients: clients}}
      end
    end
  end

  def handle_call({:mark_ready, address, pid}, _from, state) do
    {:reply, :ok, apply_mark_ready(state, address, pid)}
  end

  def handle_cast({:mark_ready, address, pid}, state) do
    {:noreply, apply_mark_ready(state, address, pid)}
  end

  defp apply_mark_ready(state, address, pid) do
    ready_before = state.ready
    ready_after = Common.mark_ready(ready_before, state.clients, address, pid)
    sync_ready_ets(ready_before, ready_after, address)
    %{state | ready: ready_after}
  end

  defp sync_ready_ets(ready_before, ready_after, address) do
    case Map.get(ready_after, address) do
      pid when is_pid(pid) ->
        Network.PeerReadyEts.insert(address, pid)

      nil ->
        if Map.has_key?(ready_before, address), do: Network.PeerReadyEts.delete(address)
    end
  end
end
