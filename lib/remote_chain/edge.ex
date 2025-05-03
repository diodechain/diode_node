# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule RemoteChain.Edge do
  alias DiodeClient.{ABI, Base16, Contracts.CallPermit, Hash, Rlp, Rlpx}
  import Network.EdgeV2, only: [response: 1, response: 2, error: 1]
  require Logger

  def handle_async_msg(chain, msg, state) do
    case msg do
      ["getblockpeak"] ->
        RemoteChain.peaknumber(chain)
        |> response()

      ["getblock", index] when is_binary(index) ->
        error("not implemented")

      ["getblockheader", index] when is_binary(index) ->
        %{
          "hash" => hash,
          "nonce" => nonce,
          "miner" => miner,
          "number" => number,
          "parentHash" => previous_block,
          "stateRoot" => state_hash,
          "timestamp" => timestamp,
          "transactionsRoot" => transaction_hash
        } = RemoteChain.RPCCache.get_block_by_number(chain, hex_blockref(index))

        %{
          "block_hash" => Base16.decode(hash),
          "miner" => Base16.decode(miner),
          "miner_signature" => nil,
          "nonce" => Base16.decode(nonce),
          "number" => Base16.decode(number),
          "state_hash" => Base16.decode(state_hash),
          "timestamp" => Base16.decode(timestamp),
          "transaction_hash" => Base16.decode(transaction_hash)
        }
        |> then(fn block ->
          if previous_block == "0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z" do
            Map.put(block, "previous_block", "0x0")
          else
            Map.put(block, "previous_block", Base16.decode(previous_block))
          end
        end)
        |> response()

      ["getblockheader2", index] when is_binary(index) ->
        error("not implemented")

      ["getblockquick", last_block, window_size]
      when is_binary(last_block) and
             is_binary(window_size) ->
        error("not implemented")

      ["getblockquick2", last_block, window_size]
      when is_binary(last_block) and
             is_binary(window_size) ->
        error("not implemented")

      ["getstateroots", _index] ->
        error("not implemented")

      ["getaccountroot", block, address] ->
        RemoteChain.RPCCache.get_account_root(
          chain,
          hex_address(address),
          hex_blockref(block)
        )
        |> Base16.decode()
        |> response()

      ["getaccount", block, address] ->
        # requires https://eips.ethereum.org/EIPS/eip-1186
        # response(Moonbeam.proof(address, [0], blockref(block)))

        code =
          RemoteChain.RPCCache.get_code(chain, hex_address(address), hex_blockref(block))
          |> Base16.decode()

        storage_root =
          RemoteChain.RPCCache.get_account_root(
            chain,
            hex_address(address),
            hex_blockref(block)
          )
          |> Base16.decode()

        response(%{
          nonce:
            RemoteChain.RPCCache.get_transaction_count(
              chain,
              hex_address(address),
              hex_blockref(block)
            )
            |> Base16.decode(),
          balance:
            RemoteChain.RPCCache.get_balance(chain, hex_address(address), hex_blockref(block))
            |> Base16.decode(),
          storage_root: storage_root,
          code: Hash.keccak_256(code)
        })

      ["getaccountroots", _index, _id] ->
        error("not implemented")

      ["getaccountvalue", block, address, key] ->
        # requires https://eips.ethereum.org/EIPS/eip-1186
        # response(Moonbeam.proof(address, [key], blockref(block)))
        RemoteChain.RPCCache.get_storage_at(
          chain,
          hex_address(address),
          hex_slot(key),
          hex_blockref(block)
        )
        |> Base16.decode()
        |> response()

      ["getaccountvalues", block, address | keys] ->
        # requires https://eips.ethereum.org/EIPS/eip-1186
        # response(Moonbeam.proof(address, keys, blockref(block)))
        RemoteChain.RPCCache.get_storage_many(
          chain,
          hex_address(address),
          Enum.map(keys, &hex_slot/1),
          hex_blockref(block)
        )
        |> Enum.map(&Base16.decode/1)
        |> response()

      ["sendtransaction", payload] ->
        case RemoteChain.RPC.send_raw_transaction(chain, Base16.encode(payload)) do
          :already_known -> response("ok")
          tx_hash when is_binary(tx_hash) -> response("ok")
          {:error, error} -> error(error)
        end

      ["getmetanonce", block, address] ->
        RemoteChain.RPC.call!(
          chain,
          Base16.encode(CallPermit.address()),
          nil,
          Base16.encode(CallPermit.nonces(address)),
          hex_blockref(block)
        )
        |> Base16.decode_int()
        |> response()

      ["sendmetatransaction", tx] ->
        if CallPermitAdapter.should_forward_metatransaction?(chain) do
          CallPermitAdapter.forward_metatransaction(chain, tx)
        else
          {to, call} = prepare_metatransaction(Rlp.decode!(tx))
          send_metatransaction(chain, to, call)
        end

      ["rpc", method, params] ->
        with {:ok, params} <- Jason.decode(params),
             result when is_map(result) <- RemoteChain.RPCCache.rpc(chain, method, params) do
          response(Jason.encode!(result))
        else
          {:error, %Jason.DecodeError{}} -> error("invalid json params")
          {:error, error} -> error(inspect(error))
        end

      _ ->
        default(msg, state)
    end
  end

  defp default(msg, state) do
    Network.EdgeV2.handle_async_msg(msg, state)
  end

  defp hex_blockref(ref) when ref in ["latest", "earliest"], do: ref

  defp hex_blockref(ref) do
    case Base16.encode(ref) do
      "0x" -> "0x0"
      "0x0" <> rest -> "0x" <> rest
      other -> other
    end
  end

  defp hex_address(<<_::binary-size(20)>> = address) do
    Base16.encode(address)
  end

  defp hex_slot(<<_::binary-size(32)>> = key) do
    Base16.encode(key)
  end

  defp hex_slot(key) when is_binary(key) do
    Base16.encode(Rlpx.bin2uint(key), false)
  end

  defp prepare_metatransaction(["dm1", id, dst, data]) do
    call = ABI.encode_call("SubmitTransaction", ["address", "bytes"], [dst, data])
    {id, call}
  end

  defp prepare_metatransaction([from, to, value, call, gaslimit, deadline, v, r, s]) do
    # These are CallPermit metatransactions
    # Testing transaction
    value = Rlpx.bin2uint(value)
    gaslimit = Rlpx.bin2uint(gaslimit)
    deadline = Rlpx.bin2uint(deadline)
    v = Rlpx.bin2uint(v)
    r = Rlpx.bin2uint(r)
    s = Rlpx.bin2uint(s)
    call = CallPermit.dispatch(from, to, value, call, gaslimit, deadline, {v, r, s})
    {CallPermit.address(), call}
  end

  defp send_metatransaction(chain, to, call) do
    # Can't do this pre-check always because we will be receiving batches of future nonces
    # those are not yet valid but will be valid in the future, after the other txs have
    # been processed...
    with false <- RemoteChain.NonceProvider.has_next_nonce?(chain),
         {:error, reason} <-
           RemoteChain.RPC.call(
             chain,
             Base16.encode(to),
             Base16.encode(Diode.address()),
             Base16.encode(call),
             "latest"
           ) do
      Logger.error("RTX rpc_call failed: #{inspect(reason)}")
      error("transaction_rejected")
    else
      _ ->
        gas_price = RemoteChain.RPC.gas_price(chain) |> Base16.decode_int()
        nonce = RemoteChain.NonceProvider.nonce(chain)

        tx =
          Shell.raw(Diode.wallet(), call,
            to: to,
            chainId: chain.chain_id(),
            gas: 12_000_000,
            gasPrice: gas_price + div(gas_price, 10),
            value: 0,
            nonce: nonce
          )

        payload =
          tx
          |> DiodeClient.Transaction.to_rlp()
          |> Rlp.encode!()
          |> Base16.encode()

        tx_hash =
          DiodeClient.Transaction.hash(tx)
          |> Base16.encode()

        Logger.info("Submitting RTX: #{tx_hash} (#{inspect(tx)})")
        # We're pushing to the TxRelay keep alive server to ensure the TX
        # is broadcasted even if the RPC connection goes down in the next call.
        # This is so to preserve the nonce ordering if at all possible
        RemoteChain.TxRelay.keep_alive(chain, tx, payload)
        RemoteChain.NonceProvider.confirm_nonce(chain, nonce)

        # In order to ensure delivery we're broadcasting to all known endpoints of this chain
        spawn(fn ->
          RemoteChain.RPC.send_raw_transaction(chain, payload)

          for endpoint <- Enum.shuffle(chain.rpc_endpoints()) do
            RemoteChain.HTTP.send_raw_transaction(endpoint, payload)
          end
        end)

        response("ok", tx_hash)
    end
  end
end
