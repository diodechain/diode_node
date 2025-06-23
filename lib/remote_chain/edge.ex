# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule RemoteChain.Edge do
  alias DiodeClient.{ABI, Base16, Contracts.CallPermit, Hash, Rlp, Rlpx, Secp256k1, Wallet}
  import Network.EdgeV2, only: [response: 1, response: 2, error: 1]
  require Logger

  def wallet_factory_address(), do: Base16.decode("0x355DdBCf0e9fD70D78829eEcb443389290Ee53E1")

  def handle_async_msg(chain, msg, state) do
    case msg do
      ["getblockpeak"] ->
        RemoteChain.peaknumber(chain)
        |> response()

      ["getblock", index] when is_binary(index) ->
        error("not implemented")

      ["getblockheader", index] when is_binary(index) ->
        get_block_header(chain, index)
        |> response()

      ["getblockheader2", index] when is_binary(index) ->
        block = get_block_header(chain, index)

        egg =
          [
            block["previous_block"],
            block["state_hash"],
            block["transaction_hash"],
            block["timestamp"],
            block["number"],
            block["nonce"]
          ]
          |> :erlang.term_to_binary(minor_version: 1)

        miner_signature =
          block["miner_signature"] ||
            raise "block header missing miner signature #{inspect(block)}"

        miner = Secp256k1.recover!(miner_signature, egg) |> Wallet.from_pubkey()
        pubkey = Wallet.pubkey!(miner)

        if block["miner"] != Wallet.address!(miner) do
          raise "invalid miner"
        end

        block = Map.delete(block, "miner")
        response(block, pubkey)

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
          to: Base16.encode(CallPermit.address()),
          data: Base16.encode(CallPermit.nonces(address)),
          block: hex_blockref(block)
        )
        |> Base16.decode_int()
        |> response()

      ["sendmetatransaction", tx] ->
        if CallPermitAdapter.should_forward_metatransaction?(chain) do
          CallPermitAdapter.forward_metatransaction(chain, tx)
        else
          {to, call, sender, min_gas_limit} = prepare_metatransaction(Rlp.decode!(tx))
          send_metatransaction(chain, to, call, sender, min_gas_limit)
        end

      ["rpc", method, params] ->
        with {:ok, params} <- Jason.decode(params),
             result when is_map(result) <- RemoteChain.RPCCache.rpc(chain, method, params) do
          response(Jason.encode!(result))
        else
          {:error, %Jason.DecodeError{}} -> error("invalid json params")
          {:error, error} -> error(inspect(error))
        end

      [other | _]
      when other in [
             "ping",
             "channel",
             "isonline",
             "getobject",
             "getnode",
             "getnodes",
             "portopen"
           ] ->
        default(msg, state)

      _ ->
        Logger.error("Unhandled message: #{inspect(msg)}")
        error("bad input")
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

  @default_gas_limit 1_000_000
  defp prepare_metatransaction(["dm0", owner, salt, impl]) do
    target = impl

    call =
      ABI.encode_call(
        "Create",
        ["address", "bytes32", "address"],
        [owner, salt, target]
      )

    {wallet_factory_address(), call, owner, @default_gas_limit}
  end

  defp prepare_metatransaction(["dm1", sender, id, nonce, deadline, dst, data, v, r, s]) do
    nonce = Rlpx.bin2uint(nonce)
    deadline = Rlpx.bin2uint(deadline)
    v = Rlpx.bin2uint(v)
    r = Rlpx.bin2uint(r)
    s = Rlpx.bin2uint(s)

    call =
      ABI.encode_call(
        "SubmitMetaTransaction",
        ["uint256", "uint256", "address", "bytes", "uint8", "bytes32", "bytes32"],
        [nonce, deadline, dst, data, v, r, s]
      )

    {id, call, sender, @default_gas_limit}
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
    {CallPermit.address(), call, from, gaslimit}
  end

  defp send_metatransaction(chain, to, call, sender, min_gas_limit) do
    # Can't do this pre-check always because we will be receiving batches of future nonces
    # those are not yet valid but will be valid in the future, after the other txs have
    # been processed...
    # 100k is for the wrapped metatransaction
    gas_limit = min_gas_limit + 100_000
    chain_id = chain.chain_id()

    with false <- RemoteChain.TxRelay.pending_sender_tx?(chain, sender),
         {:error, reason} <-
           RemoteChain.RPC.call(
             chain,
             to: Base16.encode(to),
             from: Base16.encode(Diode.address()),
             data: Base16.encode(call),
             gas: gas_limit
           ) do
      maybe_nonce = RemoteChain.NonceProvider.peek_nonce(chain)

      Logger.error(
        "RTX #{chain_id}/#{maybe_nonce} from #{Base16.encode(sender)} call failed: #{inspect(reason)}"
      )

      error("transaction_rejected")
    else
      _ ->
        gas_price = RemoteChain.RPC.gas_price(chain) |> Base16.decode_int()
        nonce = RemoteChain.NonceProvider.nonce(chain)

        tx =
          Shell.raw(Diode.wallet(), call,
            to: to,
            chainId: chain_id,
            gas: gas_limit,
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

        Logger.info(
          "RTX #{chain_id}/#{nonce} from #{Base16.encode(sender)} => #{tx_hash} (#{inspect(tx)})"
        )

        # We're pushing to the TxRelay keep alive server to ensure the TX
        # is broadcasted even if the RPC connection goes down in the next call.
        # This is so to preserve the nonce ordering if at all possible
        RemoteChain.TxRelay.keep_alive(chain, tx, payload, sender)
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

  defp get_block_header(chain, index) do
    index = Rlpx.bin2uint(index)

    %{
      "hash" => hash,
      "nonce" => nonce,
      "miner" => miner,
      "number" => number,
      "parentHash" => previous_block,
      "stateRoot" => state_hash,
      "timestamp" => timestamp,
      "transactionsRoot" => transaction_hash
    } = block = RemoteChain.RPCCache.get_block_by_number(chain, hex_blockref(index))

    miner_signature =
      case block["minerSignature"] do
        nil -> nil
        signature -> Base16.decode(signature)
      end

    %{
      "block_hash" => Base16.decode(hash),
      "miner" => Base16.decode(miner),
      "miner_signature" => miner_signature,
      "nonce" => Base16.decode_int(nonce),
      "number" => Base16.decode_int(number),
      "state_hash" => Base16.decode(state_hash),
      "timestamp" => Base16.decode_int(timestamp),
      "transaction_hash" => Base16.decode(transaction_hash)
    }
    |> then(fn block ->
      if previous_block == "0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z" do
        Map.put(block, "previous_block", "0x0")
      else
        Map.put(block, "previous_block", Base16.decode(previous_block))
      end
    end)
  end
end
