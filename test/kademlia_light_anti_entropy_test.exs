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

  defp store_rpc(parent, tag) do
    fn nodes, call ->
      case call do
        [:store, key, _value] ->
          send(parent, {tag, key, Enum.map(nodes, & &1.address)})
          Enum.map(nodes, fn _ -> ["ok"] end)

        _ ->
          Enum.map(nodes, fn _ -> [] end)
      end
    end
  end

  test "anti-entropy repairs only keys where self is in nearest-N" do
    self = Diode.wallet()
    peers = for _ <- 1..8, do: Wallet.new()
    assert :ok = Model.KademliaSql.sync_registry_nodes(Enum.map(peers, &Wallet.address!/1))

    ring = [Node.new(self) | Enum.map(peers, &Node.new/1)]
    :ets.insert(:kademlia_network, {:ring, ring})

    candidates =
      for i <- 1..80 do
        hkey = KademliaLight.hash(<<i::256>>)
        put_local(hkey, data_value(i))
        hkey
      end

    {owned, foreign} =
      Enum.split_with(candidates, fn hkey ->
        nearest = KademliaRing.nearest_n(ring, hkey, 3)
        Enum.any?(nearest, &KademliaRing.is_self/1)
      end)

    assert owned != []
    assert foreign != []

    parent = self()
    online = Map.new(peers, fn w -> {Wallet.address!(w), self()} end)

    {attempted, _cursor} =
      KademliaLight.anti_entropy_with_rpc_test(store_rpc(parent, :store), online,
        batch: 100,
        ring: ring
      )

    attempted_set =
      MapSet.new(attempted)
      |> MapSet.intersection(MapSet.new(candidates))

    assert attempted_set == MapSet.new(owned)

    for hkey <- foreign, do: refute_received({:store, ^hkey, _})
    for hkey <- attempted_set, do: assert_received({:store, ^hkey, _})
  end

  test "anti-entropy is cursor-batched and advances without reshuffling" do
    self = Diode.wallet()
    peers = for _ <- 1..2, do: Wallet.new()
    assert :ok = Model.KademliaSql.sync_registry_nodes(Enum.map(peers, &Wallet.address!/1))

    ring = [Node.new(self) | Enum.map(peers, &Node.new/1)]
    :ets.insert(:kademlia_network, {:ring, ring})

    for i <- 1..25, do: put_local(<<i::256>>, data_value(i))

    online = Map.new(peers, fn w -> {Wallet.address!(w), self()} end)
    rpc_fun = store_rpc(self(), :store)

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
    refute Enum.any?(second, &(&1 in first))

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
          put_local(hkey, data_value(i))
          hkey
        end,
        fn hkey ->
          nearest = KademliaRing.nearest_n(ring, hkey, 3)
          Enum.any?(nearest, fn %Node{address: addr} -> addr == joiner_node.address end)
        end
      )

    assert for_joiner != []
    assert not_for_joiner != []

    parent = self()
    online = %{joiner_node.address => self()}

    pushed =
      KademliaLight.join_catchup_with_rpc_test(
        joiner_node,
        store_rpc(parent, :join_store),
        online,
        ring: ring
      )

    # Join catch-up only scans the first objects_page batch.
    page_keys = MapSet.new(Enum.map(Model.KademliaSql.objects_page(nil, 100), &elem(&1, 0)))
    expected = MapSet.intersection(MapSet.new(for_joiner), page_keys)

    assert MapSet.intersection(MapSet.new(pushed), page_keys) == expected

    addr = joiner_node.address
    for hkey <- expected, do: assert_received({:join_store, ^hkey, [^addr]})

    for hkey <- not_for_joiner, MapSet.member?(page_keys, hkey) do
      refute_received {:join_store, ^hkey, _}
    end
  end

  test "join catch-up skips offline peers" do
    self = Diode.wallet()
    joiner = Wallet.new()

    assert :ok = Model.KademliaSql.sync_registry_nodes([Wallet.address!(joiner)])
    ring = [Node.new(self), Node.new(joiner)]
    :ets.insert(:kademlia_network, {:ring, ring})
    put_local(KademliaLight.hash(<<200::256>>), data_value(1))

    rpc_fun = fn _nodes, _call -> flunk("should not RPC to offline peer") end

    assert [] == KademliaLight.join_catchup_with_rpc_test(Node.new(joiner), rpc_fun, %{})
  end

  test "anti-entropy skips store RPC when no replica peers are online" do
    self = Diode.wallet()
    peer = Wallet.new()

    assert :ok = Model.KademliaSql.sync_registry_nodes([Wallet.address!(peer)])
    ring = [Node.new(self), Node.new(peer)]
    :ets.insert(:kademlia_network, {:ring, ring})

    hkey =
      Enum.find_value(1..80, fn i ->
        hkey = KademliaLight.hash(<<i + 300::256>>)
        nearest = KademliaRing.nearest_n(ring, hkey, 3)

        if Enum.any?(nearest, &KademliaRing.is_self/1) do
          put_local(hkey, data_value(i))
          hkey
        end
      end)

    assert hkey

    rpc_fun = fn _nodes, _call ->
      flunk("should not RPC when replica targets are offline")
    end

    {attempted, _} =
      KademliaLight.anti_entropy_with_rpc_test(rpc_fun, %{}, batch: 100, ring: ring)

    assert hkey in attempted
  end
end
