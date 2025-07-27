# Diode Server
# Copyright 2021-2025 Diode
# Licensed under the Diode License, Version 1.1
defmodule Contract.NodeRegistry do
  @moduledoc """
    Wrapper for the NodeRegistry contract functions, only deployed on Moonbeam
  """

  alias DiodeClient.{Base16}
  @address "0xc4b466f63c0A31302Bc8A688A7c90e1199Bb6f84" |> Base16.decode()
  @token "0x434116a99619f2B465A137199C38c1Aab0353913" |> Base16.decode()
  @chain_id 1284
  @max_uint256 115_792_089_237_316_195_423_570_985_008_687_907_853_269_984_665_640_564_039_457_584_007_913_129_639_935

  def address(), do: @address
  def token(), do: @token
  def chain_id(), do: @chain_id
  def max_uint256(), do: @max_uint256

  def register_node_transaction(accountant_address, stake) do
    Shell.transaction(
      Diode.wallet(),
      @address,
      "registerNode",
      ["address", "address", "uint256"],
      [Diode.address(), accountant_address, stake],
      chainId: @chain_id
    )
  end

  def node_info(address \\ Diode.address()) do
    Shell.call(chain_id(), @address, "nodes", ["address"], [address])
    |> DiodeClient.Base16.decode()
    |> DiodeClient.Shell.Common.decode_result("(address,address,uint256)")
    |> case do
      [accountant, address, stake] -> %{node: address, accountant: accountant, stake: stake}
      other -> {:error, "Unknown result: #{inspect(other)}"}
    end
  end

  def token_allowance() do
    Shell.call(chain_id(), @token, "allowance", ["address", "address"], [
      Diode.address(),
      @address
    ])
    |> Base16.decode()
    |> :binary.decode_unsigned()
  end

  def token_balance() do
    Shell.call(chain_id(), @token, "balanceOf", ["address"], [Diode.address()])
    |> Base16.decode()
    |> :binary.decode_unsigned()
  end

  def set_token_allowance() do
    Shell.transaction(
      Diode.wallet(),
      @token,
      "approve",
      ["address", "uint256"],
      [@address, max_uint256()],
      chainId: @chain_id
    )
    |> Diode.Transaction.execute()
  end
end
