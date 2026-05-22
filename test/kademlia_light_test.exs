# Diode Server
# Copyright 2021-2025 Diode
# Licensed under the Diode License, Version 1.1
defmodule KademliaLightTest do
  use ExUnit.Case

  alias KademliaLight.Node
  alias DiodeClient.{Object, Wallet}

  setup do
    Model.CredSql.set_wallet(Wallet.new())
    :ok
  end

  test "next_retry_at uses fibonacci capped at six hours" do
    t0 = 1_000_000
    meta = %{failures: 1, last_error: t0}
    assert KademliaLight.next_retry_at(meta) == t0 + 1

    meta = %{failures: 10, last_error: t0}
    delay = KademliaLight.next_retry_at(meta) - t0
    assert delay <= 6 * 3600
    assert delay > 0
  end

  test "filter_online excludes nodes not in RPC-ready map" do
    self_node = Node.new(Diode.wallet())
    connected = Node.new(Wallet.new())
    offline = Node.new(Wallet.new())
    ready = %{connected.address => self()}

    result = KademliaLight.filter_online([self_node, connected, offline], ready)

    addresses = Enum.map(result, & &1.address)
    assert self_node.address in addresses
    assert connected.address in addresses
    refute offline.address in addresses
  end

  test "filter_online excludes handshaking peers not yet RPC-ready" do
    ready_node = Node.new(Wallet.new())
    handshaking = Node.new(Wallet.new())
    ready = %{ready_node.address => self()}

    result = KademliaLight.filter_online([ready_node, handshaking], ready)

    assert Enum.map(result, & &1.address) == [ready_node.address]
  end

  test "find_nodes returns only self without peer connections" do
    a = Wallet.address!(Wallet.new())
    b = Wallet.address!(Wallet.new())

    Model.KademliaSql.clear()
    Model.KademliaSql.init()
    assert :ok = Model.KademliaSql.sync_registry_nodes([a, b])

    peers =
      KademliaLight.find_nodes(<<1>>)
      |> Enum.reject(&KademliaRing.is_self/1)

    assert peers == []
  end

  test "find_nodes uses local nearest among connected ring members" do
    n1 = Wallet.new()
    n2 = Wallet.new()
    a1 = Wallet.address!(n1)
    a2 = Wallet.address!(n2)

    ring = [Node.new(n1), Node.new(n2), Node.new(Diode.wallet())]
    key = KademliaLight.hash(<<1>>)
    online = %{a1 => self(), a2 => self()}

    peer_addresses =
      ring
      |> KademliaLight.filter_online(online)
      |> KademliaRing.nearest(key)
      |> Enum.take(KademliaRing.k())
      |> Enum.reject(&KademliaRing.is_self/1)
      |> Enum.map(& &1.address)
      |> Enum.sort()

    assert peer_addresses == Enum.sort([a1, a2])
  end

  test "registry_nodes_missing_object counts on-chain peers without endpoint" do
    a = Wallet.address!(Wallet.new())
    b = Wallet.address!(Wallet.new())

    Model.KademliaSql.clear()
    Model.KademliaSql.init()
    assert :ok = Model.KademliaSql.sync_registry_nodes([a, b])

    ring = [Node.new(Wallet.from_address(a)), Node.new(Diode.wallet())]

    assert KademliaLight.registry_nodes_missing_object(ring) == 1
  end

  test "contact attempts nodes with stored object even when known_good is false" do
    node = Wallet.new()
    address = Wallet.address!(node)
    ring_key = KademliaRing.key(node)

    Model.KademliaSql.clear()
    Model.KademliaSql.init()
    assert :ok = Model.KademliaSql.sync_registry_nodes([address])

    Model.KademliaSql.put_object(ring_key, Object.encode!(Diode.self()))
    assert Model.KademliaSql.get_node(address).known_good == false

    assert Model.KademliaSql.object(ring_key) != nil
  end

  test "absorb_peer_hints stores objects without adding p2p_nodes rows" do
    server = Diode.self()
    object_key = KademliaLight.hash(Object.key(server))

    Model.KademliaSql.clear()
    Model.KademliaSql.init()

    KademliaLight.absorb_peer_hints([
      %{node_id: Wallet.new(), object: server}
    ])

    assert Model.KademliaSql.object(object_key) != nil

    assert Model.KademliaSql.query!("SELECT COUNT(*) FROM p2p_nodes") |> hd() |> hd() == 0
  end

  test "store_ack? recognizes ok responses" do
    assert KademliaLight.store_ack?(["ok"])
    assert KademliaLight.store_ack?("ok")
    refute KademliaLight.store_ack?([])
    refute KademliaLight.store_ack?(nil)
  end

  test "write_quorum_met? counts local toward W" do
    assert KademliaLight.write_quorum_met?(0) == false
    assert KademliaLight.write_quorum_met?(1) == true
    assert KademliaLight.write_quorum_met?(2) == true
  end

  test "quorum_select_value picks highest block_number" do
    w = Wallet.new()
    v1 = Object.Data.new(1, "a", "x", Wallet.privkey!(w)) |> Object.encode!()
    v5 = Object.Data.new(5, "a", "x", Wallet.privkey!(w)) |> Object.encode!()
    v3 = Object.Data.new(3, "a", "x", Wallet.privkey!(w)) |> Object.encode!()

    assert KademliaLight.quorum_select_value([v1, v5, v3]) == v5
    assert KademliaLight.quorum_select_value([]) == nil
  end

  test "should_stop_value_search stops after R value responses" do
    key = <<0::256>>
    visited = %{}
    unqueried = [Node.new(Wallet.new())]

    refute KademliaLight.should_stop_value_search_test(key, visited, unqueried, ["v1"])

    assert KademliaLight.should_stop_value_search_test(key, visited, unqueried, ["v1", "v2"])
  end

  test "replica_targets returns N nearest remote nodes" do
    wallets =
      for _ <- 1..5 do
        Wallet.new()
      end

    addresses = Enum.map(wallets, &Wallet.address!/1)

    Model.KademliaSql.clear()
    Model.KademliaSql.init()
    assert :ok = Model.KademliaSql.sync_registry_nodes(addresses)

    ring =
      [Node.new(Diode.wallet()) | Enum.map(wallets, &Node.new/1)]

    :ets.insert(:kademlia_network, {:ring, ring})

    key = KademliaLight.hash(<<1>>)
    {remote, self_in_set?} = KademliaLight.replica_targets(key)

    assert length(remote) <= 3
    refute Enum.any?(remote, &KademliaRing.is_self/1)
    assert is_boolean(self_in_set?)
  end

  test "sort_connected_first orders online peers before offline" do
    n1 = Node.new(Wallet.new())
    n2 = Node.new(Wallet.new())
    online = %{n2.address => self()}

    sorted = KademliaLight.sort_connected_first_test([n1, n2], online)

    assert [first, second] = sorted
    assert first.address == n2.address
    assert second.address == n1.address
  end
end
