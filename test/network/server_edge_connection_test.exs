# Diode Server
# Copyright 2021-2025 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.ServerEdgeConnectionTest do
  use ExUnit.Case

  alias DiodeClient.Wallet

  @moduletag :capture_log

  setup do
    port = 59100 + rem(System.unique_integer([:positive]), 1000)
    name = :"edge_server_test_#{port}"

    {:ok, _pid} =
      Network.EdgeServer.start_link({[port], %{name: name}})

    on_exit(fn ->
      if pid = Process.whereis(name) do
        GenServer.stop(pid, :normal, 1000)
      end
    end)

    {:ok, server: name, port: port}
  end

  defp register_device(server, peer, address, port) do
    GenServer.call(server, {:register, peer, address, port}, 5000)
  end

  defp spawn_handler(server, peer, address, port) do
    parent = self()

    spawn(fn ->
      send(parent, {:handler, self()})

      case register_device(server, peer, address, port) do
        {:ok, _} -> send(parent, {:registered, self()})
        other -> send(parent, {:register_failed, other})
      end

      receive do
        :hang -> :ok
      end
    end)
  end

  test "duplicate register keeps both handlers alive", %{server: server} do
    peer = Wallet.new()
    key = Wallet.address!(peer)

    spawn_handler(server, peer, {10, 0, 0, 1}, 11_111)
    assert_receive {:handler, p1}
    assert_receive {:registered, ^p1}

    spawn_handler(server, peer, {10, 0, 0, 2}, 22_222)
    assert_receive {:handler, p2}
    assert_receive {:registered, ^p2}

    assert Process.alive?(p1)
    assert Process.alive?(p2)
    assert Network.EdgeServer.get_connections(server)[key] == p2

    st = :sys.get_state(server)
    assert Map.get(st.clients, p1) == key
  end

  test "duplicate register does not kill_clone first connection", %{server: server} do
    peer = Wallet.new()

    spawn_handler(server, peer, {10, 0, 0, 3}, 33_333)
    assert_receive {:handler, p1}
    assert_receive {:registered, ^p1}

    ref = Process.monitor(p1)

    spawn_handler(server, peer, {10, 0, 0, 4}, 44_444)
    assert_receive {:handler, p2}
    assert_receive {:registered, ^p2}

    refute_receive {:DOWN, ^ref, :process, ^p1, :kill_clone}, 500
    assert Process.alive?(p1)

    Process.exit(p1, :kill)
    Process.exit(p2, :kill)
  end
end
