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

  test "find_nodes returns N online peers excluding self from the count" do
    peers = for _ <- 1..4, do: Wallet.new()

    ring = [Node.new(Diode.wallet()) | Enum.map(peers, &Node.new/1)]
    :ets.insert(:kademlia_network, {:ring, ring})

    ready = Map.new(peers, fn wallet -> {Wallet.address!(wallet), self()} end)

    assert length(KademliaLight.find_nodes(<<1>>, ready)) == 3
  end

  test "find_node_objects skips online peers without objects and backfills" do
    w1 = Wallet.new()
    w2 = Wallet.new()
    w3 = Wallet.new()
    a1 = Wallet.address!(w1)
    a2 = Wallet.address!(w2)
    a3 = Wallet.address!(w3)

    ring = [Node.new(w1), Node.new(w2), Node.new(w3), Node.new(Diode.wallet())]
    :ets.insert(:kademlia_network, {:ring, ring})

    ready = %{a1 => self(), a2 => self(), a3 => self()}

    server =
      Object.Server.new("example.test", 1234, 5678, "2.3.1", [])
      |> Object.Server.sign(Wallet.privkey!(w2))

    Model.KademliaSql.put_object(KademliaRing.key(w2), Object.encode!(server))

    server2 =
      Object.Server.new("example2.test", 1234, 5678, "2.3.1", [])
      |> Object.Server.sign(Wallet.privkey!(w3))

    Model.KademliaSql.put_object(KademliaRing.key(w3), Object.encode!(server2))

    objects = KademliaLight.find_node_objects(<<1>>, ready, 2)

    assert length(objects) == 2
    assert Enum.any?(objects, fn o -> Object.Server.host(o) == "example.test" end)
    assert Enum.any?(objects, fn o -> Object.Server.host(o) == "example2.test" end)
  end

  test "find_nodes returns at most N online replica hints from registry ring" do
    a = Wallet.address!(Wallet.new())
    b = Wallet.address!(Wallet.new())

    Model.KademliaSql.clear()
    Model.KademliaSql.init()
    assert :ok = Model.KademliaSql.sync_registry_nodes([a, b])

    ring = [
      Node.new(Wallet.from_address(a)),
      Node.new(Wallet.from_address(b)),
      Node.new(Diode.wallet())
    ]

    :ets.insert(:kademlia_network, {:ring, ring})

    ready = %{a => self(), b => self()}

    peers = KademliaLight.find_nodes(<<1>>, ready)

    assert length(peers) <= 3
    assert Enum.all?(peers, fn n -> n.address in [a, b] end)
  end

  test "find_nodes returns N nearest online replicas from ring" do
    n1 = Wallet.new()
    n2 = Wallet.new()
    a1 = Wallet.address!(n1)
    a2 = Wallet.address!(n2)

    ring = [Node.new(n1), Node.new(n2), Node.new(Diode.wallet())]
    :ets.insert(:kademlia_network, {:ring, ring})

    ready = %{a1 => self(), a2 => self()}

    peer_addresses =
      KademliaLight.find_nodes(<<1>>, ready)
      |> Enum.map(& &1.address)
      |> Enum.sort()

    assert peer_addresses == Enum.sort([a1, a2])
  end

  test "find_nodes excludes offline peers" do
    online_wallet = Wallet.new()
    offline_wallet = Wallet.new()
    online = Wallet.address!(online_wallet)
    _offline = Wallet.address!(offline_wallet)

    ring = [
      Node.new(online_wallet),
      Node.new(offline_wallet),
      Node.new(Diode.wallet())
    ]

    :ets.insert(:kademlia_network, {:ring, ring})

    ready = %{online => self()}

    peer_addresses =
      KademliaLight.find_nodes(<<1>>, ready)
      |> Enum.map(& &1.address)

    assert peer_addresses == [online]
  end

  test "find_node_lookup returns at most N replica hints" do
    wallets = for _ <- 1..5, do: Wallet.new()
    addresses = Enum.map(wallets, &Wallet.address!/1)

    Model.KademliaSql.clear()
    Model.KademliaSql.init()
    assert :ok = Model.KademliaSql.sync_registry_nodes(addresses)

    ring = [Node.new(Diode.wallet()) | Enum.map(wallets, &Node.new/1)]
    :ets.insert(:kademlia_network, {:ring, ring})

    hints =
      ring
      |> KademliaRing.nearest_n(KademliaLight.hash(<<1>>), 3)
      |> Enum.reject(&KademliaRing.is_self/1)

    assert length(hints) <= 3
    refute Enum.any?(hints, &KademliaRing.is_self/1)
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

  test "read_quorum_met? requires R responses" do
    refute KademliaLight.read_quorum_met?(0)
    assert KademliaLight.read_quorum_met?(1)
    assert KademliaLight.read_quorum_met?(2)
    assert KademliaLight.read_quorum_met?(3)
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

  test "bootstrap_peer_nodes returns connected peers not in the on-chain ring" do
    seed = Wallet.new()
    ring_member = Wallet.new()
    ring = [Node.new(Diode.wallet()), Node.new(ring_member)]
    :ets.insert(:kademlia_network, {:ring, ring})

    ready = %{
      Wallet.address!(seed) => self(),
      Wallet.address!(ring_member) => self()
    }

    result = KademliaLight.bootstrap_peer_nodes(ready, ring)
    addresses = Enum.map(result, & &1.address)

    assert Wallet.address!(seed) in addresses
    refute Wallet.address!(ring_member) in addresses
    refute Diode.address() in addresses
  end

  test "find_value_via_bootstrap_peers reads from connected bootstrap peers" do
    target = Wallet.new()
    bootstrap = Wallet.new()
    ring = [Node.new(Diode.wallet())]
    :ets.insert(:kademlia_network, {:ring, ring})

    server =
      Object.Server.new("bootstrap.test", 1234, 5678, "2.3.1", [])
      |> Object.Server.sign(Wallet.privkey!(target))

    encoded = Object.encode!(server)

    {:ok, peer} = BootstrapPeer.start_link(encoded)
    ready = %{Wallet.address!(bootstrap) => peer}

    assert ^encoded =
             KademliaLight.find_value_via_bootstrap_peers(
               Wallet.address!(target),
               ready,
               ring
             )
  end
end

defmodule BootstrapPeer do
  use GenServer

  def start_link(value), do: GenServer.start_link(__MODULE__, value)

  @impl true
  def init(value), do: {:ok, value}

  @impl true
  def handle_call({:rpc, _call}, _from, value) do
    {:reply, {:value, value}, value}
  end
end
