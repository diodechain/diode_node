# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Shell do
  @moduledoc """
    Examples:

    me = Diode.miner() |> Wallet.address!()
    Shell.get_balance(me)

    fleetContract = Base16.decode("0x6728c7bea74db60c2fb117c15de28b0b0686c389")
    Shell.call(fleetContract, "accountant")

    registryContract = Diode.registry_address()
    Shell.call(registryContract, "ContractStake", ["address"], [fleetContract])

    addr = Chain.GenesisFactory.genesis_accounts |> hd |> elem(0)
    Shell.call_from(Wallet.from_address(addr), registryContract, "ContractStake", ["address"], [fleetContract])
  """

  def call(chain_id, address, name, types \\ [], values \\ [], opts \\ [])
      when is_list(types) and is_list(values) do
    call_from(chain_id, Diode.miner(), address, name, types, values, opts)
  end

  def call_from(chain_id, wallet, address, name, types \\ [], values \\ [], opts \\ [])
      when is_list(types) and is_list(values) do
    opts =
      opts
      |> Keyword.put_new(:gas, 10_000_000)
      |> Keyword.put_new(:gasPrice, 0)
      |> Keyword.put_new(:chain_id, chain_id)

    tx = transaction(wallet, address, name, types, values, opts, false)
    blockRef = Keyword.get(opts, :blockRef, "latest")
    call_tx(tx, blockRef)
  end

  def submit_tx(_tx) do
    :todo
  end

  def call_tx(_tx, _blockRef) do
    :todo
  end

  def transaction(wallet, address, name, types, values, opts \\ [], sign \\ true)
      when is_list(types) and is_list(values) do
    # https://solidity.readthedocs.io/en/v0.4.24/abi-spec.html
    opts = Keyword.put(opts, :to, address)
    callcode = ABI.encode_call(name, types, values)
    raw(wallet, callcode, opts, sign)
  end

  def constructor(wallet, code, types, values, opts \\ [], sign \\ true) do
    # https://solidity.readthedocs.io/en/v0.4.24/abi-spec.html
    callcode = code <> ABI.encode_args(types, values)
    raw(wallet, callcode, opts, sign)
  end

  def raw(wallet, callcode, opts \\ [], sign \\ true) do
    opts =
      opts
      |> Keyword.put_new(:gas, 10_000_000)
      |> Keyword.put_new(:gasPrice, 0)
      |> Enum.map(fn {key, value} -> {Atom.to_string(key), value} end)
      |> Map.new()

    Network.Rpc.create_transaction(wallet, callcode, opts, sign)
  end

  def get_balance(_chain_id, _address) do
    :todo
  end

  @spec get_miner_stake(non_neg_integer(), binary()) :: non_neg_integer()
  def get_miner_stake(chain_id, address) do
    {value, _gas} =
      call(Chain.registry_address(chain_id), "MinerValue", ["uint8", "address"], [0, address])

    :binary.decode_unsigned(value)
  end

  def get_slot(_address, _slot) do
    :todo
  end

  def ether(x), do: 1000 * finney(x)
  def finney(x), do: 1000 * szabo(x)
  def szabo(x), do: 1000 * gwei(x)
  def gwei(x), do: 1000 * mwei(x)
  def mwei(x), do: 1000 * kwei(x)
  def kwei(x), do: 1000 * wei(x)
  def wei(x) when is_integer(x), do: x
end
