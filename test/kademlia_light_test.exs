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

  test "filter_online excludes disconnected registry nodes" do
    self_node = Node.new(Diode.wallet())
    connected = Node.new(Wallet.new())
    offline = Node.new(Wallet.new())
    online = %{connected.address => self()}

    result = KademliaLight.filter_online([self_node, connected, offline], online)

    addresses = Enum.map(result, & &1.address)
    assert self_node.address in addresses
    assert connected.address in addresses
    refute offline.address in addresses
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

    node_count_before =
      Model.KademliaSql.query!("SELECT COUNT(*) FROM p2p_nodes") |> hd() |> hd()

    KademliaLight.absorb_peer_hints([
      %{node_id: Wallet.new(), object: server}
    ])

    assert Model.KademliaSql.object(object_key) != nil

    node_count_after =
      Model.KademliaSql.query!("SELECT COUNT(*) FROM p2p_nodes") |> hd() |> hd()

    assert node_count_after == node_count_before
  end
end
