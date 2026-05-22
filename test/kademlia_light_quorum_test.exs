# Diode Server
# Copyright 2021-2025 Diode
# Licensed under the Diode License, Version 1.1
defmodule KademliaLightQuorumTest do
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
    Object.Data.new(block, "quorum", "v#{block}", Wallet.privkey!(Wallet.new()))
    |> Object.encode!()
  end

  test "store quorum met with one remote ack" do
    value = data_value(1)
    key = <<10::256>>
    peer = Wallet.new()

    assert :ok = Model.KademliaSql.sync_registry_nodes([Wallet.address!(peer)])

    :ets.insert(:kademlia_network, {
      :ring,
      [Node.new(Diode.wallet()), Node.new(peer)]
    })

    online = %{Wallet.address!(peer) => self()}

    rpc_fun = fn nodes, _call ->
      Enum.map(nodes, fn _ -> ["ok"] end)
    end

    assert :ok = KademliaLight.store_with_rpc(key, value, rpc_fun, online)
  end

  test "store quorum fallback succeeds on second batch" do
    value = data_value(1)
    key = <<11::256>>

    wallets = for _ <- 1..5, do: Wallet.new()
    addresses = Enum.map(wallets, &Wallet.address!/1)
    assert :ok = Model.KademliaSql.sync_registry_nodes(addresses)

    ring = [Node.new(Diode.wallet()) | Enum.map(wallets, &Node.new/1)]
    :ets.insert(:kademlia_network, {:ring, ring})

    {:ok, batch_agent} = Agent.start_link(fn -> 0 end)

    rpc_fun = fn nodes, _call ->
      n = Agent.get_and_update(batch_agent, &{&1 + 1, &1 + 1})

      if n == 1 do
        Enum.map(nodes, fn _ -> [] end)
      else
        Enum.map(nodes, fn _ -> ["ok"] end)
      end
    end

    online =
      wallets
      |> Enum.map(fn w -> {Wallet.address!(w), self()} end)
      |> Map.new()

    assert :ok = KademliaLight.store_with_rpc(key, value, rpc_fun, online)
  end

  test "store quorum does not rpc when no peers are RPC-ready" do
    value = data_value(1)
    key = <<15::256>>

    wallets = for _ <- 1..3, do: Wallet.new()
    addresses = Enum.map(wallets, &Wallet.address!/1)
    assert :ok = Model.KademliaSql.sync_registry_nodes(addresses)

    ring = [Node.new(Diode.wallet()) | Enum.map(wallets, &Node.new/1)]
    :ets.insert(:kademlia_network, {:ring, ring})

    {:ok, agent} = Agent.start_link(fn -> nil end)

    rpc_fun = fn nodes, _call ->
      Agent.update(agent, fn _ -> Enum.map(nodes, & &1.address) end)
      Enum.map(nodes, fn _ -> [] end)
    end

    assert {:error, :quorum_not_met, %{acked: 1, tried: _}} =
             KademliaLight.store_with_rpc(key, value, rpc_fun)

    assert Agent.get(agent, fn _ -> nil end) == nil
  end

  test "store quorum not met when all remotes fail" do
    value = data_value(1)
    key = <<12::256>>

    rpc_fun = fn _nodes, _call ->
      [[]]
    end

    assert {:error, :quorum_not_met, %{acked: 1, tried: _}} =
             KademliaLight.store_with_rpc(key, value, rpc_fun)
  end

  test "find_value quorum selects newest among R responses in one batch" do
    key = <<13::256>>
    n1 = Node.new(Wallet.new())
    n2 = Node.new(Wallet.new())
    n3 = Node.new(Wallet.new())

    addresses = Enum.map([n1, n2, n3], & &1.address)
    assert :ok = Model.KademliaSql.sync_registry_nodes(addresses)

    ring = [Node.new(Diode.wallet()), n1, n2, n3]
    :ets.insert(:kademlia_network, {:ring, ring})

    online = Map.new([n1, n2, n3], fn n -> {n.address, self()} end)

    v1 = data_value(1)
    v5 = data_value(5)
    v3 = data_value(3)

    rpc_fun = fn nodes, _call ->
      Enum.map(nodes, fn
        %{address: addr} when addr == n1.address -> {:value, v1}
        %{address: addr} when addr == n2.address -> {:value, v5}
        %{address: addr} when addr == n3.address -> {:value, v3}
        _ -> []
      end)
    end

    result = KademliaLight.find_value_with_rpc(key, rpc_fun, online)

    assert result == v5
  end

  test "find_value returns nil when read quorum not met and no local copy" do
    key = <<16::256>>
    peer = Wallet.new()
    assert :ok = Model.KademliaSql.sync_registry_nodes([Wallet.address!(peer)])

    ring = [Node.new(Diode.wallet()), Node.new(peer)]
    :ets.insert(:kademlia_network, {:ring, ring})

    online = %{Wallet.address!(peer) => self()}

    rpc_fun = fn _nodes, _call -> [[]] end

    assert KademliaLight.find_value_with_rpc(key, rpc_fun, online) == nil
  end

  test "repair_replicas pushes store to connected replica targets" do
    key = <<14::256>>
    hkey = KademliaLight.hash(key)
    value = data_value(10)

    wallets = for _ <- 1..4, do: Wallet.new()
    addresses = Enum.map(wallets, &Wallet.address!/1)
    assert :ok = Model.KademliaSql.sync_registry_nodes(addresses)

    ring = [Node.new(Diode.wallet()) | Enum.map(wallets, &Node.new/1)]
    :ets.insert(:kademlia_network, {:ring, ring})

    online = Map.new(wallets, fn w -> {Wallet.address!(w), self()} end)

    {replica_remote, _} = KademliaLight.replica_targets(key, online)
    assert replica_remote != []

    parent = self()

    rpc_fun = fn nodes, call ->
      case call do
        [:store, ^hkey, ^value] ->
          send(parent, {:repair_store, length(nodes)})
          Enum.map(nodes, fn _ -> ["ok"] end)

        _ ->
          Enum.map(nodes, fn _ -> [] end)
      end
    end

    online =
      Map.new(replica_remote, fn %Node{address: address} -> {address, self()} end)

    :ok = KademliaLight.repair_replicas_with_rpc_test(key, value, rpc_fun, online)

    assert_receive {:repair_store, n}
    assert n >= 1
  end
end
