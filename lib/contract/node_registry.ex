# Diode Server
# Copyright 2021-2025 Diode
# Licensed under the Diode License, Version 1.1
defmodule Contract.NodeRegistry do
  @moduledoc """
    Wrapper for the NodeRegistry contract functions, only deployed on Moonbeam
  """

  alias DiodeClient.{Base16, Hash, MetaTransaction, Rlp}
  @address "0xD2AeC9B1DE400b9eb222d7B6e727c6Ad1D77cA2D" |> Base16.decode()
  @token "0x434116a99619f2B465A137199C38c1Aab0353913" |> Base16.decode()
  @chain_id 1284
  @max_uint256 115_792_089_237_316_195_423_570_985_008_687_907_853_269_984_665_640_564_039_457_584_007_913_129_639_935

  def address(), do: @address
  def token(), do: @token
  def chain_id(), do: @chain_id
  def max_uint256(), do: @max_uint256

  def register_node_transaction(node_address, accountant_address, stake) do
    Shell.transaction(
      Diode.wallet(),
      @address,
      "registerNode",
      ["address", "address", "uint256"],
      [node_address, accountant_address, stake],
      chainId: @chain_id
    )
  end

  def accountant() do
    Shell.call(chain_id(), @address, "nodes", ["address"], [Diode.address()], "latest")
    |> Hash.to_address()
  end

  def token_allowance() do
    Shell.call(chain_id(), @token, "allowance", ["address", "address"], [
      Diode.address(),
      @address
    ])
    |> Base16.decode()
    |> :binary.decode_unsigned()
  end

  def set_token_allowance(amount) do
    Shell.transaction(
      Diode.wallet(),
      @token,
      "approve",
      ["address", "uint256"],
      [@address, amount],
      chainId: @chain_id
    )
    |> execute()
  end

  def execute(tx) do
    case Shell.call_tx!(tx, "latest") do
      "0x" ->
        chain = RemoteChain.chainimpl(chain_id())
        nonce = RemoteChain.NonceProvider.nonce(chain_id())
        tx = %DiodeClient.Transaction{tx | nonce: nonce}

        txhash =
          if CallPermitAdapter.should_forward_metatransaction?(chain) do
            tx =
              MetaTransaction.sign(
                %MetaTransaction{
                  from: Diode.address(),
                  to: tx.to,
                  call: tx.data,
                  gaslimit: tx.gasLimit,
                  deadline: System.os_time(:second) + 3600,
                  value: tx.value,
                  nonce: tx.nonce,
                  chain_id: chain_id()
                },
                Diode.wallet()
              )
              |> MetaTransaction.to_rlp()
              |> Rlp.encode!()

            case CallPermitAdapter.forward_metatransaction(chain, tx) do
              ["ok", txhash] -> txhash
              other -> {:error, other}
            end
          else
            Shell.submit_tx(tx)
          end

        if is_binary(txhash) do
          RemoteChain.NonceProvider.confirm_nonce(chain_id(), tx.nonce)
          {:ok, txhash}
        else
          RemoteChain.NonceProvider.cancel_nonce(chain_id(), tx.nonce)
          {:error, txhash}
        end

      {{:evmc_revert, reason}, _} ->
        {:error, "EVM error: #{inspect(reason)}"}

      other ->
        {:error, "Unknown error: #{inspect(other)}"}
    end
  end
end
