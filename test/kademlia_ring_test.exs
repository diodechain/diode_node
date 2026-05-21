# Diode Server
# Copyright 2021-2025 Diode
# Licensed under the Diode License, Version 1.1
defmodule KademliaRingTest do
  use ExUnit.Case

  alias KademliaLight.Node
  alias KademliaRing
  alias DiodeClient.Wallet

  setup do
    Model.CredSql.set_wallet(node_id("abcd"))
  end

  test "nearest on flat list" do
    nodes = nodes(100)
    self_node = Node.new(Diode.wallet())
    all = [self_node | nodes]

    near = KademliaRing.nearer_n(all, Diode.wallet(), Diode.wallet(), KademliaRing.k())
    assert Enum.any?(near, &KademliaRing.is_self/1)
    assert length(near) == 1

    opposite = binary_not(KademliaRing.key(node_id("abcd")))
    near = KademliaRing.nearest_n(all, opposite, KademliaRing.k())
    refute Enum.any?(near, &KademliaRing.is_self/1)
    assert length(near) == 20

    ref =
      all
      |> Enum.sort(fn a, b ->
        KademliaRing.distance(opposite, a) < KademliaRing.distance(opposite, b)
      end)
      |> Enum.take(20)
      |> Enum.sort()

    assert ref == Enum.sort(near)
  end

  test "symmetric distance" do
    for x <- 1..100 do
      a = node_id("distance_a_#{x}")
      b = node_id("distance_b_#{x}")
      assert KademliaRing.distance(a, b) == KademliaRing.distance(b, a)
    end
  end

  test "unique" do
    items = [
      Node.new(node_id([1])),
      Node.new(node_id([1]))
    ]

    unique = KademliaRing.unique(items)
    assert length(unique) == 1
  end

  test "prev and next ring order" do
    nodes = nodes(10)
    self_node = Node.new(Diode.wallet())
    all = [self_node | nodes]

    ring = KademliaRing.to_ring_list(all, self_node)
    assert length(ring) == length(all) - 1

    [first | _] = KademliaRing.next(all, self_node)
    assert first in ring
  end

  defp binary_not(bin) do
    :erlang.binary_to_list(bin)
    |> Enum.map(fn x -> rem(x + 128, 256) end)
    |> :erlang.list_to_binary()
  end

  def nodes(num) do
    Enum.map(1..num, fn idx ->
      Node.new(node_id([idx]))
    end)
  end

  def node_id(x) do
    Wallet.from_privkey(Diode.hash(x))
  end
end
