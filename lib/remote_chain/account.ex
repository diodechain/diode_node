# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule RemoteChain.Account do
  defstruct nonce: 0, balance: 0, storage_root: nil, code: nil, root_hash: nil

  @type t :: %RemoteChain.Account{
          nonce: non_neg_integer(),
          balance: non_neg_integer(),
          storage_root: MerkleTree.t(),
          code: binary() | nil,
          root_hash: nil
        }

  def new(props \\ []) do
    acc = %RemoteChain.Account{}

    Enum.reduce(props, acc, fn {key, value}, acc ->
      Map.put(acc, key, value)
    end)
  end

  def code(%RemoteChain.Account{code: nil}), do: ""
  def code(%RemoteChain.Account{code: code}), do: code
  def nonce(%RemoteChain.Account{nonce: nonce}), do: nonce
  def balance(%RemoteChain.Account{balance: balance}), do: balance

  @spec tree(RemoteChain.Account.t()) :: MerkleTree.t()
  def tree(%RemoteChain.Account{storage_root: nil}), do: MapMerkleTree.new()
  def tree(%RemoteChain.Account{storage_root: root}), do: root

  def put_tree(%RemoteChain.Account{} = acc, root) do
    %RemoteChain.Account{acc | storage_root: root, root_hash: nil}
  end

  def root_hash(%RemoteChain.Account{root_hash: nil} = acc) do
    MerkleTree.root_hash(tree(acc))
  end

  def root_hash(%RemoteChain.Account{root_hash: root_hash}) do
    root_hash
  end

  def compact(%RemoteChain.Account{} = acc) do
    tree = MerkleTree.compact(tree(acc))

    if MerkleTree.size(tree) == 0 do
      %RemoteChain.Account{acc | storage_root: nil}
    else
      %RemoteChain.Account{acc | storage_root: tree}
    end
  end

  def normalize(%RemoteChain.Account{root_hash: hash} = acc) when is_binary(hash) do
    acc
  end

  def normalize(%RemoteChain.Account{root_hash: nil} = acc) do
    acc = %RemoteChain.Account{acc | storage_root: MerkleTree.merkle(tree(acc))}
    %RemoteChain.Account{acc | root_hash: root_hash(acc)}
  end

  def storage_set_value(acc, key = <<_k::256>>, value = <<_v::256>>) do
    store = MerkleTree.insert(tree(acc), key, value)
    %RemoteChain.Account{acc | storage_root: store, root_hash: nil}
  end

  def storage_set_value(acc, key, value) when is_integer(key) do
    storage_set_value(acc, <<key::unsigned-size(256)>>, value)
  end

  def storage_set_value(acc, key, value) when is_integer(value) do
    storage_set_value(acc, key, <<value::unsigned-size(256)>>)
  end

  @spec storage_value(RemoteChain.Account.t(), binary() | integer()) :: binary() | nil
  def storage_value(acc, key) when is_integer(key) do
    storage_value(acc, <<key::unsigned-size(256)>>)
  end

  def storage_value(%RemoteChain.Account{} = acc, key) when is_binary(key) do
    case MerkleTree.get(tree(acc), key) do
      nil -> <<0::unsigned-size(256)>>
      bin -> bin
    end
  end

  @spec to_rlp(RemoteChain.Account.t()) :: [...]
  def to_rlp(%RemoteChain.Account{} = account) do
    [
      account.nonce,
      account.balance,
      root_hash(account),
      codehash(account)
    ]
  end

  @spec hash(RemoteChain.Account.t()) :: binary()
  def hash(%RemoteChain.Account{} = account) do
    Diode.hash(Rlp.encode!(to_rlp(account)))
  end

  @empty_hash Diode.hash("")
  def codehash(%RemoteChain.Account{code: nil}) do
    @empty_hash
  end

  def codehash(%RemoteChain.Account{code: code}) do
    Diode.hash(code)
  end
end
