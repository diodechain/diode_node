# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule MapMerkleTree do
  # ========================================================
  # Public Functions only in the facade
  # ========================================================
  def new() do
    {MapMerkleTree, %{}, %{}}
  end

  # ========================================================
  # Wrapper functions for the impls
  # ========================================================
  def merkle(tree) do
    HeapMerkleTree.new()
    |> MerkleTree.insert_items(to_list(tree))
  end

  def root_hash(tree) do
    MerkleTree.root_hash(merkle(tree))
  end

  def root_hashes(tree) do
    MerkleTree.root_hashes(merkle(tree))
  end

  def get_proofs(tree, key) do
    MerkleTree.get_proofs(merkle(tree), key)
  end

  def get({MapMerkleTree, _opts, dict}, key) do
    Map.get(dict, key)
  end

  def size({MapMerkleTree, _opts, dict}) do
    map_size(dict)
  end

  def bucket_count(tree) do
    MerkleTree.bucket_count(merkle(tree))
  end

  def to_list({MapMerkleTree, _opts, dict}) do
    Map.to_list(dict)
  end

  def delete({MapMerkleTree, opts, dict}, key) do
    {MapMerkleTree, opts, Map.delete(dict, key)}
  end

  def member?({MapMerkleTree, _opts, dict}, key) do
    Map.has_key?(dict, key)
  end

  def insert_items({MapMerkleTree, opts, dict}, items) do
    dict = for item <- items, into: dict, do: item
    {MapMerkleTree, opts, dict}
  end
end