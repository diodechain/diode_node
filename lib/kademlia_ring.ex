# Diode Server
# Copyright 2021-2025 Diode
# Licensed under the Diode License, Version 1.1
defmodule KademliaRing do
  @moduledoc """
  Geometric ring distance and neighbor queries over a flat node list.
  """
  alias DiodeClient.Wallet
  alias KademliaLight.Node
  import Wallet

  @k 20

  def k(), do: @k

  def distance(a, b) do
    dist = abs(integer(a) - integer(b))

    if dist > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF do
      0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF - dist
    else
      dist
    end
  end

  def key(wallet() = w) do
    Diode.hash(Wallet.address!(w))
  end

  def key(%Node{ring_key: ring_key}) when is_binary(ring_key), do: ring_key

  def key(%Node{node_id: wallet() = w}) do
    key(w)
  end

  def key(<<key::bitstring-size(256)>>) do
    key
  end

  def key(address) when is_binary(address) and byte_size(address) == 20 do
    Diode.hash(address)
  end

  def integer(<<x::integer-size(256)>>) do
    x
  end

  def integer(item) do
    integer(key(item))
  end

  def nearest(nodes, item) when is_list(nodes) do
    nodes
    |> Enum.sort_by(fn a -> distance(item, a) end)
  end

  def nearest_n(nodes, item, n) when is_list(nodes) do
    nearest(nodes, item)
    |> Enum.take(n)
  end

  def nearer_n(nodes, self_id, item, n) do
    min_dist = distance(self_id, item)

    nearest_n(nodes, item, n)
    |> Enum.filter(fn a -> distance(a, item) <= min_dist end)
  end

  def to_ring_list(nodes, nil) do
    to_ring_list(nodes, Diode.wallet())
  end

  def to_ring_list(nodes, item) do
    key = integer(item)

    {pre, post} =
      nodes
      |> Enum.reject(fn a -> integer(a) == key end)
      |> Enum.sort(fn a, b -> integer(a) < integer(b) end)
      |> Enum.split_while(fn a -> integer(a) < key end)

    post ++ pre
  end

  def next(nodes, item \\ nil) do
    to_ring_list(nodes, item)
  end

  def next_n(nodes, item \\ nil, n) do
    to_ring_list(nodes, item)
    |> Enum.take(n)
  end

  def prev(nodes, item \\ nil) do
    to_ring_list(nodes, item)
    |> Enum.reverse()
  end

  def prev_n(nodes, item \\ nil, n) do
    to_ring_list(nodes, item)
    |> Enum.reverse()
    |> Enum.take(n)
  end

  def to_map(list) when is_list(list) do
    Enum.reduce(list, %{}, fn node, acc ->
      Map.put(acc, key(node), node)
    end)
  end

  def unique(list) when is_list(list) do
    to_map(list)
    |> Map.values()
  end

  def is_self(%Node{node_id: node_id}) do
    Wallet.equal?(node_id, Diode.wallet())
  end

  def is_self(node_id) do
    Wallet.equal?(node_id, Diode.wallet())
  end

  def member?(nodes, item_id) do
    key = key(item_id)

    Enum.any?(nodes, fn node -> key(node) == key end)
  end

  def find(nodes, item_id) do
    key = key(item_id)

    Enum.find(nodes, fn node -> key(node) == key end)
  end
end
