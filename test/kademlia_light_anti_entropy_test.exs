# Diode Server
# Copyright 2021-2026 Diode
# Licensed under the Diode License, Version 1.1
defmodule KademliaLightAntiEntropyTest do
  use ExUnit.Case

  alias KademliaLight.Node
  alias DiodeClient.{Object, Wallet}

  setup do
    Model.CredSql.set_wallet(Wallet.new())
    Model.KademliaSql.clear()
    Model.KademliaSql.init()
    :ok
  end

  defp data_value(block) do
    Object.Data.new(block, "anti_entropy", "v#{block}", Wallet.privkey!(Wallet.new()))
    |> Object.encode!()
  end

  defp put_local(hkey, value) do
    Model.KademliaSql.put_object(hkey, value)
  end

  test "anti-entropy repairs only keys where self is in nearest-N" do
    self = Diode.wallet()
    peers = for _ <- 1..8, do: Wallet.new()
    addresses = Enum.map(peers, &Wallet.address!/1)
    assert :ok = Model.KademliaSql.sync_registry_nodes(addresses)

    ring = [Node.new(self) | Enum.map(peers, &Node.new/1)]
    :ets.insert(:kademlia_network, {:ring, ring})

    candidates =
      for i <- 1..80 do
        hkey = KademliaLight.hash(<<i::256>>)
        value = data_value(i)
        put_local(hkey, value)
        {hkey, value}
      end

    # Live GenServer may reload :ring after sync; pin again before classification/run.
    :ets.insert(:kademlia_network, {:ring, ring})

    {owned, foreign} =
      Enum.split_with(candidates, fn {hkey, _} ->
        nearest = KademliaRing.nearest_n(ring, hkey, 3)
        Enum.any?(nearest, &KademliaRing.is_self/1)
      end)

    assert owned != []
    assert foreign != []

    parent = self()

    rpc_fun = fn nodes, call ->
      case call do
        [:store, key, _value] ->
          send(parent, {:store, key, Enum.map(nodes, & &1.address)})
          Enum.map(nodes, fn _ -> ["ok"] end)

        _ ->
          Enum.map(nodes, fn _ -> [] end)
      end
    end

    online = Map.new(peers, fn w -> {Wallet.address!(w), self()} end)

    {repaired, _cursor} =
      KademliaLight.anti_entropy_with_rpc_test(rpc_fun, online, batch: 100, ring: ring)

    repaired_set = MapSet.new(repaired)
    owned_set = MapSet.new(Enum.map(owned, &elem(&1, 0)))
    foreign_set = MapSet.new(Enum.map(foreign, &elem(&1, 0)))
    candidate_set = MapSet.union(owned_set, foreign_set)

    # Ignore any background objects outside this test's planted keys.
    repaired_set = MapSet.intersection(repaired_set, candidate_set)

    assert MapSet.subset?(repaired_set, owned_set)
    assert MapSet.disjoint?(repaired_set, foreign_set)
    assert repaired_set == owned_set

    for {hkey, _} <- foreign do
      refute_received {:store, ^hkey, _}
    end

    for hkey <- repaired_set do
      assert_received {:store, ^hkey, _}
    end
  end

  test "anti-entropy is cursor-batched and advances without reshuffling" do
    self = Diode.wallet()
    # Only two peers so self is always in nearest-3 for every key
    peers = for _ <- 1..2, do: Wallet.new()
    addresses = Enum.map(peers, &Wallet.address!/1)
    assert :ok = Model.KademliaSql.sync_registry_nodes(addresses)

    ring = [Node.new(self) | Enum.map(peers, &Node.new/1)]
    :ets.insert(:kademlia_network, {:ring, ring})

    for i <- 1..25 do
      hkey = <<i::256>>
      put_local(hkey, data_value(i))
    end

    parent = self()

    rpc_fun = fn _nodes, call ->
      case call do
        [:store, key, _value] ->
          send(parent, {:store, key})
          [["ok"]]

        _ ->
          [[]]
      end
    end

    online = Map.new(peers, fn w -> {Wallet.address!(w), self()} end)

    {first, cursor1} =
      KademliaLight.anti_entropy_with_rpc_test(rpc_fun, online,
        cursor: nil,
        batch: 10,
        ring: ring
      )

    assert length(first) == 10
    assert cursor1 == <<10::256>>

    {second, cursor2} =
      KademliaLight.anti_entropy_with_rpc_test(rpc_fun, online,
        cursor: cursor1,
        batch: 10,
        ring: ring
      )

    assert length(second) == 10
    assert cursor2 == <<20::256>>
    refute Enum.any?(second, fn key -> key in first end)

    {third, cursor3} =
      KademliaLight.anti_entropy_with_rpc_test(rpc_fun, online,
        cursor: cursor2,
        batch: 10,
        ring: ring
      )

    assert length(third) == 5
    assert cursor3 == nil
  end

  test "join catch-up stores only keys where peer is in nearest-N" do
    self = Diode.wallet()
    joiner = Wallet.new()
    others = for _ <- 1..7, do: Wallet.new()

    assert :ok =
             Model.KademliaSql.sync_registry_nodes([
               Wallet.address!(joiner) | Enum.map(others, &Wallet.address!/1)
             ])

    ring = [Node.new(self), Node.new(joiner) | Enum.map(others, &Node.new/1)]
    :ets.insert(:kademlia_network, {:ring, ring})

    joiner_node = Node.new(joiner)

    {for_joiner, not_for_joiner} =
      Enum.split_with(
        for i <- 1..80 do
          hkey = KademliaLight.hash(<<i + 100::256>>)
          value = data_value(i)
          put_local(hkey, value)
          {hkey, value}
        end,
        fn {hkey, _} ->
          nearest = KademliaRing.nearest_n(ring, hkey, 3)
          Enum.any?(nearest, fn %Node{address: addr} -> addr == joiner_node.address end)
        end
      )

    assert for_joiner != []
    assert not_for_joiner != []

    parent = self()

    rpc_fun = fn nodes, call ->
      case call do
        [:store, key, _value] ->
          send(parent, {:join_store, key, Enum.map(nodes, & &1.address)})
          Enum.map(nodes, fn _ -> ["ok"] end)

        _ ->
          Enum.map(nodes, fn _ -> [] end)
      end
    end

    online = %{joiner_node.address => self()}

    pushed =
      KademliaLight.join_catchup_with_rpc_test(joiner_node, rpc_fun, online, ring: ring)

    page_keys =
      Model.KademliaSql.objects_page(nil, 100)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    expected =
      for_joiner
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()
      |> MapSet.intersection(page_keys)

    assert MapSet.new(pushed) |> MapSet.intersection(page_keys) == expected

    for hkey <- expected do
      addr = joiner_node.address
      assert_received {:join_store, ^hkey, [^addr]}
    end

    for {hkey, _} <- not_for_joiner, MapSet.member?(page_keys, hkey) do
      refute_received {:join_store, ^hkey, _}
    end
  end

  test "join catch-up skips offline peers" do
    self = Diode.wallet()
    joiner = Wallet.new()

    assert :ok = Model.KademliaSql.sync_registry_nodes([Wallet.address!(joiner)])
    ring = [Node.new(self), Node.new(joiner)]
    :ets.insert(:kademlia_network, {:ring, ring})

    hkey = KademliaLight.hash(<<200::256>>)
    put_local(hkey, data_value(1))

    rpc_fun = fn _nodes, _call ->
      flunk("should not RPC to offline peer")
    end

    assert [] ==
             KademliaLight.join_catchup_with_rpc_test(Node.new(joiner), rpc_fun, %{})
  end

  test "anti-entropy skips store RPC when no replica peers are online" do
    self = Diode.wallet()
    peer = Wallet.new()

    assert :ok = Model.KademliaSql.sync_registry_nodes([Wallet.address!(peer)])
    ring = [Node.new(self), Node.new(peer)]
    :ets.insert(:kademlia_network, {:ring, ring})

    # Find a key where self is a rightful replica
    {hkey, _value} =
      Enum.find_value(1..80, fn i ->
        hkey = KademliaLight.hash(<<i + 300::256>>)
        nearest = KademliaRing.nearest_n(ring, hkey, 3)

        if Enum.any?(nearest, &KademliaRing.is_self/1) do
          value = data_value(i)
          put_local(hkey, value)
          {hkey, value}
        end
      end)

    assert hkey

    rpc_fun = fn _nodes, _call ->
      flunk("should not RPC when replica targets are offline")
    end

    {repaired, _} =
      KademliaLight.anti_entropy_with_rpc_test(rpc_fun, %{}, batch: 100, ring: ring)

    # Self is responsible so key is selected, but repair finds no online remotes
    assert hkey in repaired
  end
end
