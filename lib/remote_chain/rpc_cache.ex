# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule RemoteChain.RPCCache do
  use GenServer, restart: :permanent
  require Logger
  # alias RemoteChain.RPC
  alias RemoteChain.NodeProxy
  alias RemoteChain.RPCCache
  alias RemoteChain.Cache

  defstruct [
    :chain,
    :cache,
    :block_number,
    :request_rpc,
    :request_from,
    :request_collection,
    :block_number_requests
  ]

  def start_link([chain, cache]) do
    GenServer.start_link(__MODULE__, {chain, cache}, name: name(chain), hibernate_after: 5_000)
  end

  @impl true
  def init({chain, cache}) do
    # NodeProxy.subscribe_block(chain)

    {:ok,
     %__MODULE__{
       chain: chain,
       cache: cache,
       block_number: nil,
       request_rpc: %{},
       request_from: %{},
       request_collection: :gen_server.reqids_new(),
       block_number_requests: []
     }}
  end

  def block_number(chain) do
    case GenServer.call(name(chain), :block_number) do
      number when number != nil -> number
    end
  end

  def get_block_by_number(chain, block \\ "latest", with_transactions \\ false) do
    block = resolve_block(chain, block)
    rpc!(chain, "eth_getBlockByNumber", [block, with_transactions])
  end

  def get_storage_at(chain, address, slot, block \\ "latest") do
    block = resolve_block(chain, block)
    rpc!(chain, "eth_getStorageAt", [address, slot, block])
  end

  def get_storage_many(chain, address, slots, block \\ "latest") do
    block = resolve_block(chain, block)
    calls = Enum.map(slots, fn slot -> {:rpc, "eth_getStorageAt", [address, slot, block]} end)

    RemoteChain.Util.batch_call(name(chain), calls, 15_000)
    |> Enum.map(fn
      {:reply, %{"result" => result}} ->
        result

      {:reply, %{"error" => error}} ->
        raise "RPC error in get_storage_many(#{inspect({chain, address, slots, block})}): #{inspect(error)}"

      {:error, reason} ->
        raise "Batch error in get_storage_many(#{inspect({chain, address, slots, block})}): #{inspect(reason)}"

      :timeout ->
        raise "Timeout error in get_storage_many(#{inspect({chain, address, slots, block})})"
    end)
  end

  def call(chain, to, from, data, block \\ "latest") do
    rpc!(chain, "eth_call", [%{to: to, data: data, from: from}, block])
  end

  def get_code(chain, address, block \\ "latest") do
    rpc!(chain, "eth_getCode", [address, block])
  end

  def get_transaction_count(chain, address, block \\ "latest") do
    block = resolve_block(chain, block)
    rpc!(chain, "eth_getTransactionCount", [address, block])
  end

  def get_balance(chain, address, block \\ "latest") do
    block = resolve_block(chain, block)
    rpc!(chain, "eth_getBalance", [address, block])
  end

  def get_account_root(chain, address, block \\ "latest")
      when chain in [Chains.MoonbaseAlpha, Chains.Moonbeam, Chains.Moonriver] do
    block = resolve_block(chain, block)

    # this code is specific to Moonbeam (EVM on Substrate) simulating the account_root

    # this is modulname and storage name hashed and concatenated
    # from this document: https://www.shawntabrizi.com/blog/substrate/querying-substrate-storage-via-rpc/#storage-keys
    # Constant prefix for '?.?'
    # prefix = Base16.decode("0x26AA394EEA5630E07C48AE0C9558CEF7B99D880EC681799C0CF30E8886371DA9")
    # Constant prefix for 'evm.accountStorages'
    prefix = Base.decode16!("1DA53B775B270400E7E61ED5CBC5A146AB1160471B1418779239BA8E2B847E42")
    bin_address = Base16.decode(address)
    {:ok, storage_item_key} = :eblake2.blake2b(16, bin_address)
    storage_key = Base16.encode(prefix <> storage_item_key <> bin_address)

    # fetching the polkadot relay hash for the corresponding block
    # `block` is always a block number (not a block hash)
    # and we're assuming that polkadot relay chain and evm chain are in sync
    block_hash = rpc!(chain, "chain_getBlockHash", [block])

    # To emulate a storage root that only changes when
    # any of the slots has changed we do this:
    # 1) Fetch all account keys
    # => because there can be many account keys and fetching them all can be slow
    # => we're guessing here on change for more than 20 keys
    keys =
      rpc!(chain, "state_getKeys", [storage_key, block_hash])
      |> Enum.map(fn key -> "0x" <> binary_part(key, byte_size(key) - 40, 40) end)
      |> Enum.sort()

    if length(keys) < 40 do
      values = get_storage_many(chain, address, keys, block)

      Enum.zip(keys, values)
      |> Enum.map(fn {key, value} -> key <> value end)
      |> Enum.join()
      |> Hash.keccak_256()
    else
      # since this is a heuristic, it can be wrong and might miss some changes
      # so we force fresh every week
      base =
        div(Base16.decode_int(block) + Base16.decode_int(address), 50_000) |> Base16.encode(false)

      Enum.join([base | keys])
      |> Hash.keccak_256()
    end
    |> Base16.encode()
  end

  def rpc!(chain, method, params) do
    case rpc(chain, method, params) do
      %{"result" => ret} ->
        ret

      other ->
        raise "RPC error in #{inspect(chain)}.#{method}(#{inspect(params)}): #{inspect(other)}"
    end
  end

  def rpc(chain, method, params) do
    GenServer.call(name(chain), {:rpc, method, params})
  end

  @impl true
  def handle_call(
        :block_number,
        from,
        state = %RPCCache{block_number: nil, block_number_requests: requests}
      ) do
    {:noreply, %RPCCache{state | block_number_requests: [from | requests]}}
  end

  def handle_call(:block_number, _from, state = %RPCCache{block_number: number}) do
    {:reply, number, state}
  end

  def handle_call(
        {:rpc, method, params},
        from,
        state = %RPCCache{
          chain: chain,
          cache: cache,
          request_rpc: request_rpc,
          request_collection: col
        }
      ) do
    case Cache.get(cache, {chain, method, params}) do
      nil ->
        case Map.get(request_rpc, {method, params}) do
          nil ->
            col =
              :gen_server.send_request(
                NodeProxy.name(chain),
                {:rpc, method, params},
                {method, params},
                col
              )

            request_rpc = Map.put(request_rpc, {method, params}, MapSet.new([from]))
            {:noreply, %RPCCache{state | request_rpc: request_rpc, request_collection: col}}

          set ->
            request_rpc = Map.put(request_rpc, {method, params}, MapSet.put(set, from))
            {:noreply, %RPCCache{state | request_rpc: request_rpc}}
        end

      result ->
        {:reply, result, state}
    end
  end

  @impl true
  def handle_info(
        {{NodeProxy, _chain}, :block_number, block_number},
        state = %RPCCache{block_number_requests: requests}
      ) do
    for from <- requests do
      GenServer.reply(from, block_number)
    end

    {:noreply, %RPCCache{state | block_number: block_number, block_number_requests: []}}
  end

  def handle_info(
        msg,
        state = %RPCCache{
          cache: cache,
          chain: chain,
          request_collection: col,
          request_rpc: request_rpc
        }
      ) do
    case :gen_server.check_response(msg, col, true) do
      :no_request ->
        Logger.info("#{__MODULE__}(#{chain}) received no_request: #{inspect(msg)}")
        {:noreply, state}

      :no_reply ->
        Logger.info("#{__MODULE__}(#{chain}) received no_reply: #{inspect(msg)}")
        {:noreply, state}

      {ret, {method, params}, col} ->
        {state, ret} =
          case ret do
            {:reply, ret} ->
              state =
                if should_cache_method(method, params) and should_cache_result(ret) do
                  %RPCCache{state | cache: Cache.put(cache, {chain, method, params}, ret)}
                else
                  state
                end

              {state, ret}

            {:error, _reason} ->
              {state, ret}
          end

        {froms, request_rpc} = Map.pop!(request_rpc, {method, params})
        for from <- froms, do: GenServer.reply(from, ret)
        state = %RPCCache{state | request_collection: col, request_rpc: request_rpc}
        {:noreply, state}
    end
  end

  def resolve_block(chain, "latest"), do: hex_blockref(block_number(chain))
  def resolve_block(_chain, block) when is_integer(block), do: hex_blockref(block)
  def resolve_block(_chain, "0x" <> _ = block), do: hex_blockref(Base16.decode_int(block))

  defp hex_blockref(ref) when ref in ["latest", "earliest"], do: ref

  defp hex_blockref(ref) do
    case Base16.encode(ref, false) do
      "0x" -> "0x0"
      "0x0" <> rest -> "0x" <> rest
      other -> other
    end
  end

  defp name(nil), do: raise("Chain `nil` not found")

  defp name(chain) do
    impl = RemoteChain.chainimpl(chain)
    {:global, {__MODULE__, impl}}
  end

  defp should_cache_method("dio_edgev2", [hex]) do
    case hd(Rlp.decode!(Base16.decode(hex))) do
      "ticket" -> false
      _other -> true
    end
  end

  defp should_cache_method(_method, _args) do
    # IO.inspect({method, params}, label: "should_cache_method")
    true
  end

  defp should_cache_result(_ret) do
    # IO.inspect(ret, label: "should_cache_result")
    true
  end
end
