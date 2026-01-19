defmodule Diode.Transaction do
  alias DiodeClient.{Base16, Contracts.CallPermit, MetaTransaction, Rlp}

  def execute(tx) do
    chain_id = tx.chain_id

    case Shell.call_tx!(tx, "latest") do
      "0x" <> _ ->
        chain = RemoteChain.chainimpl(chain_id)

        if CallPermitAdapter.should_forward_metatransaction?(chain) do
          tx =
            %MetaTransaction{
              from: Diode.address(),
              to: tx.to,
              call: tx.data,
              gaslimit: tx.gasLimit,
              deadline: System.os_time(:second) + 3600,
              value: tx.value,
              nonce: get_meta_nonce(chain_id, Diode.address()),
              chain_id: chain_id
            }
            |> MetaTransaction.sign(Diode.wallet())
            |> MetaTransaction.to_rlp()
            |> Rlp.encode!()

          case CallPermitAdapter.forward_metatransaction(chain, tx) do
            ["response", "ok", txhash] -> {:ok, txhash}
            other -> {:error, other}
          end
        else
          nonce = RemoteChain.NonceProvider.nonce(chain_id)
          tx = %{tx | nonce: nonce}
          txhash = Shell.submit_tx(tx)

          if is_binary(txhash) do
            RemoteChain.NonceProvider.confirm_nonce(chain_id, nonce)
            {:ok, txhash}
          else
            RemoteChain.NonceProvider.cancel_nonce(chain_id, nonce)
            {:error, txhash}
          end
        end

      {{:evmc_revert, reason}, _} ->
        {:error, "EVM error: #{inspect(reason)}"}

      other ->
        {:error, "Unknown error: #{inspect(other)}"}
    end
  end

  defp get_meta_nonce(chain_id, address) do
    RemoteChain.RPC.call!(
      chain_id,
      to: Base16.encode(CallPermit.address()),
      data: Base16.encode(CallPermit.nonces(address)),
      block: "latest"
    )
    |> Base16.decode_int()
  end
end
