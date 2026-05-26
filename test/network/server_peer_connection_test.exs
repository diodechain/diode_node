# Diode Server
# Copyright 2021-2025 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.ServerPeerConnectionTest do
  use ExUnit.Case

  alias DiodeClient.Wallet

  @moduletag :capture_log

  setup do
    port = 59000 + rem(System.unique_integer([:positive]), 1000)
    name = :"peer_server_test_#{port}"

    {:ok, _pid} =
      Network.PeerServer.start_link({[port], %{name: name}})

    on_exit(fn ->
      case Process.whereis(name) do
        pid when is_pid(pid) ->
          if Process.alive?(pid) do
            try do
              GenServer.stop(pid, :normal, 1000)
            catch
              :exit, {:noproc, _} -> :ok
            end
          end

        _ ->
          :ok
      end
    end)

    {:ok, server: name, port: port}
  end

  defp register_peer(server, peer, address, port) do
    GenServer.call(server, {:register, peer, address, port}, 5000)
  end

  defp spawn_handler(server, peer, address, port) do
    parent = self()

    spawn(fn ->
      send(parent, {:handler, self()})

      case register_peer(server, peer, address, port) do
        {:ok, _} -> send(parent, {:registered, self()})
        other -> send(parent, {:register_failed, other})
      end

      receive do
        :hang -> :ok
      end
    end)
  end

  defp client_entry?(entry) when is_tuple(entry) do
    tuple_size(entry) in [2, 4] and is_pid(elem(entry, 0))
  end

  defp client_entry?(_), do: false

  test "register stores 4-tuple client entry visible to get_connections", %{server: server} do
    peer = Wallet.new()
    key = Wallet.address!(peer)

    spawn_handler(server, peer, {127, 0, 0, 1}, 12_345)
    assert_receive {:handler, handler_pid}
    assert_receive {:registered, ^handler_pid}

    st = :sys.get_state(server)
    assert client_entry?(Map.get(st.clients, key))
    assert Map.get(st.clients, handler_pid) == key

    conns = Network.PeerServer.get_connections(server)
    assert conns[key] == handler_pid
  end

  test "ensure_node_connection reuses in-flight outbound dial", %{server: server} do
    peer = Wallet.new()
    key = Wallet.address!(peer)
    parent = self()

    dialer =
      spawn(fn ->
        pid = Network.PeerServer.ensure_node_connection(peer, "127.0.0.1", 59_999, server)
        send(parent, {:dial, pid})
        Process.sleep(:infinity)
      end)

    assert_receive {:dial, worker}
    assert Network.PeerServer.ensure_node_connection(peer, "127.0.0.1", 59_999, server) == worker

    st = :sys.get_state(server)
    assert client_entry?(Map.get(st.clients, key))
    assert Map.get(st.clients, worker) == key

    Process.exit(dialer, :kill)
  end

  test "outbound ensure then register from same handler keeps one slot", %{server: server} do
    peer = Wallet.new()
    key = Wallet.address!(peer)
    parent = self()

    handler =
      spawn(fn ->
        send(parent, {:handler, self()})
        {:ok, _} = register_peer(server, peer, {127, 0, 0, 1}, 59_999)
        send(parent, {:registered, self()})
        Process.sleep(:infinity)
      end)

    assert_receive {:handler, ^handler}
    assert_receive {:registered, ^handler}

    :sys.replace_state(server, fn state ->
      clients =
        state.clients
        |> Map.put(key, {handler, System.os_time(:millisecond), "127.0.0.1", 59_999})
        |> Map.put(handler, key)

      %{state | clients: clients}
    end)

    assert Network.PeerServer.ensure_node_connection(peer, "127.0.0.1", 59_999, server) == handler

    Process.exit(handler, :kill)
  end

  test "mark_ready accepts 4-tuple client entries", %{server: server} do
    peer = Wallet.new()
    key = Wallet.address!(peer)

    spawn_handler(server, peer, {127, 0, 0, 1}, 12_345)
    assert_receive {:handler, handler_pid}
    assert_receive {:registered, ^handler_pid}

    :ok = GenServer.call(server, {:mark_ready, key, handler_pid})

    ready = Network.PeerServer.get_ready_connections(server)
    assert ready[key] == handler_pid
  end

  test "duplicate register kills stale handler with kill_clone", %{server: server} do
    peer = Wallet.new()
    key = Wallet.address!(peer)

    spawn_handler(server, peer, {10, 0, 0, 1}, 11_111)
    assert_receive {:handler, p1}
    assert_receive {:registered, ^p1}

    ref = Process.monitor(p1)

    spawn_handler(server, peer, {10, 0, 0, 2}, 22_222)
    assert_receive {:handler, p2}
    assert_receive {:registered, ^p2}

    assert_receive {:DOWN, ^ref, :process, ^p1, :kill_clone}, 2000
    refute Process.alive?(p1)
    assert Process.alive?(p2)
    assert Network.PeerServer.get_connections(server)[key] == p2

    Process.exit(p2, :kill)
  end

  test "duplicate register does not crash the server", %{server: server} do
    peer = Wallet.new()

    spawn_handler(server, peer, {10, 0, 0, 1}, 11_111)
    assert_receive {:handler, p1}
    assert_receive {:registered, ^p1}

    spawn_handler(server, peer, {10, 0, 0, 2}, 22_222)
    assert_receive {:handler, p2}
    assert_receive {:registered, ^p2}

    assert Process.alive?(Process.whereis(server))
    Process.exit(p1, :kill)
    Process.exit(p2, :kill)
  end
end
