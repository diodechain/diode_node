# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule KademliaTest do
  use ExUnit.Case, async: false
  alias Network.Server, as: Server
  alias Network.PeerHandlerV2, as: PeerHandler
  import TestHelper
  import While

  # Need bigger number to have a not connected network
  # 30
  @network_size 50
  @testkey Wallet.new()
  setup_all do
    reset()
    :io.format("KademliaLight starting clones~n")
    start_clones(@network_size)

    on_exit(fn ->
      kill_clones()
    end)
  end

  defp new_value(name, value) do
    Object.Data.new(peaknumber(), name, value, Wallet.privkey!(@testkey))
  end

  defp find_value(name) do
    KademliaLight.find_value(Object.Data.key(Wallet.address!(@testkey), name))
    |> case do
      nil -> nil
      other -> Object.decode!(other)
    end
  end

  defp connect_clones(range) do
    pid = Server.ensure_node_connection(PeerHandler, nil, "localhost", Diode.peer2_port())
    assert GenServer.call(pid, {:rpc, [PeerHandler.ping()]}) == [PeerHandler.pong()]

    for n <- range do
      pid = Server.ensure_node_connection(PeerHandler, nil, "localhost", peer_port(n))

      ret =
        try do
          GenServer.call(pid, {:rpc, [PeerHandler.ping()]}, 15_000)
        rescue
          _error ->
            IO.puts(inspect(Process.info(pid, :current_stacktrace)))
        catch
          _type, _error ->
            IO.puts(inspect(Process.info(pid, :current_stacktrace)))
        end

      assert ret == [PeerHandler.pong()]
    end
  end

  test "connect" do
    wait_for(
      fn -> Server.get_connections(PeerHandler) == %{} end,
      "connections to drain"
    )

    conns = Server.get_connections(PeerHandler)
    assert map_size(conns) == 0
    connect_clones(1..@network_size)
    assert map_size(Server.get_connections(PeerHandler)) == @network_size + 1

    # For network size > k() not all nodes might be stored
    if @network_size < KBuckets.k(),
      do: assert(KBuckets.size(KademliaLight.network()) == @network_size + 1)
  end

  test "send/receive" do
    connect_clones(1..@network_size)

    values = Enum.map(1..100, fn idx -> new_value("#{idx}", "value_#{idx}") end)
    before = Process.list()

    :io.format("KademliaLight store")

    for value <- values do
      :io.format(" #{Object.Data.name(value)}")
      KademliaLight.store(value)
    end

    :io.format("~nKademlia find_value ")

    for value <- values do
      :io.format(" #{Object.Data.name(value)}")
      assert find_value(Object.Data.name(value)) == value
    end

    for value <- values do
      :io.format("not_#{Object.Data.name(value)}")
      assert find_value("not_#{Object.Data.name(value)}") == nil
    end

    :io.format("~n")

    assert length(before) >= length(Process.list())
  end

  @tag timeout: 120_000
  test "redistribute" do
    connect_clones(1..@network_size)

    values = Enum.map(1..100, fn idx -> new_value("re_#{idx}", "value_#{idx}") end)
    :io.format("KademliaLight store")

    for value <- values do
      :io.format(" #{Object.Data.name(value)}")
      KademliaLight.store(value)
    end

    :io.format("~n")

    before = KBuckets.size(KademliaLight.network())

    while KBuckets.size(KademliaLight.network()) < before + 1 do
      :io.format("Adding clone~n")
      new_clone = count_clones() + 1
      add_clone(new_clone)
      wait_clones(new_clone, 60)
      connect_clones(1..new_clone)
    end

    assert KBuckets.size(KademliaLight.network()) == before + 1

    for value <- values do
      :io.format("KademliaLight find_value #{Object.Data.name(value)}~n")
      assert find_value(Object.Data.name(value)) == value
    end
  end

  test "failed server" do
    values = Enum.map(1..50, fn idx -> new_value("#{idx}", "value_#{idx}") end)

    :io.format("KademliaLight store")

    for value <- values do
      :io.format(" #{Object.Data.name(value)}")
      KademliaLight.store(value)
    end

    :io.format("~n")

    freeze_clone(1)

    :io.format("KademliaLight find_value")

    for value <- values do
      :io.format(" #{Object.Data.name(value)}")
      assert find_value(Object.Data.name(value)) == value
    end

    :io.format("~n")

    unfreeze_clone(1)
  end
end
