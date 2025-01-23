# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Shell do
  @moduledoc false
  alias DiodeClient.{ABI, Base16, Rlp, Transaction}
  alias RemoteChain.NodeProxy

  def call(chain_id, address, name, types \\ [], values \\ [], opts \\ [])
      when is_list(types) and is_list(values) do
    call_from(chain_id, Diode.wallet(), address, name, types, values, opts)
  end

  def call_from(chain_id, wallet, address, name, types \\ [], values \\ [], opts \\ [])
      when is_list(types) and is_list(values) do
    {tx, blockRef} = tx_from(chain_id, wallet, address, name, types, values, opts)
    call_tx!(tx, blockRef)
  end

  def tx_from(chain_id, wallet, address, name, types \\ [], values \\ [], opts \\ [])
      when is_list(types) and is_list(values) do
    {blockRef, opts} =
      opts
      |> Keyword.put_new(:gas, 10_000_000)
      |> Keyword.put_new(:nonce, 0)
      |> Keyword.put_new(:gasPrice, 0)
      |> Keyword.put_new(:chainId, chain_id)
      |> Keyword.pop(:blockRef, "latest")

    {transaction(wallet, address, name, types, values, opts, false), blockRef}
  end

  def submit_tx(tx) do
    id = DiodeClient.Transaction.chain_id(tx)
    hex = DiodeClient.Transaction.to_rlp(tx) |> Rlp.encode!() |> Base16.encode()
    RemoteChain.RPC.send_raw_transaction(id, hex)
  end

  def await_tx(tx) do
    case submit_tx(tx) do
      tx_id when is_binary(tx_id) -> await_tx_id({tx_id, tx})
      error -> raise "Failed to submit transaction: #{inspect(error)}"
    end
  end

  def await_tx_id({tx_id, tx}) do
    NodeProxy.subscribe_block(Transaction.chain_id(tx))

    case RemoteChain.RPC.get_transaction_by_hash(Transaction.chain_id(tx), tx_id) do
      nil ->
        NodeProxy.unsubscribe_block(Transaction.chain_id(tx))

        raise "Awaiting transaction (nil?!): #{tx_id} #{inspect(Base16.encode(Transaction.hash(tx)))}"

      %{"blockNumber" => nil} ->
        receive do
          {{NodeProxy, _chain}, :block_number, _block_number} ->
            await_tx_id({tx_id, tx})
        after
          5000 ->
            IO.puts("Awaiting transaction: #{tx_id}")
            await_tx_id({tx_id, tx})
        end

      %{"blockNumber" => block_number} ->
        NodeProxy.unsubscribe_block(Transaction.chain_id(tx))
        block_number
    end
  end

  def call_tx!(tx, blockRef) do
    RemoteChain.RPC.call!(
      Transaction.chain_id(tx),
      Transaction.to(tx) |> Base16.encode(),
      Transaction.from(tx) |> Base16.encode(),
      Transaction.payload(tx) |> Base16.encode(),
      blockRef
    )
  end

  def call_tx(tx, blockRef) do
    RemoteChain.RPC.call(
      Transaction.chain_id(tx),
      Transaction.to(tx) |> Base16.encode(),
      Transaction.from(tx) |> Base16.encode(),
      Transaction.payload(tx) |> Base16.encode(),
      blockRef
    )
  end

  def debug_tx(tx, url, blockRef) do
    RemoteChain.HTTP.rpc(url, "debug_traceCall", [
      %{
        to: Transaction.to(tx) |> Base16.encode(),
        data: Transaction.payload(tx) |> Base16.encode(),
        from: Transaction.from(tx) |> Base16.encode()
      },
      blockRef
    ])
  end

  def reload(modules) do
    loader_dir = ~c"/opt/diode_node/"

    if List.first(:code.get_path()) != loader_dir do
      :code.add_patha(loader_dir)
    end

    for mod <- List.wrap(modules) do
      :code.load_file(mod)
      Process.sleep(1000)
      :code.purge(mod)
      mod.module_info(:compile)
    end
  end

  def transaction(wallet, to, name, types, values, opts \\ [], sign \\ true)
      when is_list(types) and is_list(values) do
    # https://solidity.readthedocs.io/en/v0.4.24/abi-spec.html
    opts = Keyword.put(opts, :to, to)
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
      |> Enum.map(fn {key, value} -> {Atom.to_string(key), value} end)
      |> Map.new()

    Network.Rpc.create_transaction(wallet, callcode, opts, sign)
  end

  def get_balance(chain_id, address = <<_::binary-size(20)>>) do
    RemoteChain.RPC.get_balance(chain_id, Base16.encode(address)) |> Base16.decode_int()
  end

  @spec get_miner_stake(non_neg_integer(), binary()) :: non_neg_integer()
  def get_miner_stake(chain_id, address) do
    {value, _gas} =
      call(RemoteChain.registry_address(chain_id), "MinerValue", ["uint8", "address"], [
        0,
        address
      ])

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

  def trace_moon_tx(tx_hash) do
    # _pid = spawn_link(fn ->
    #   System.cmd("anvil", ["--steps-tracing", "--fork-url", "https://moonbeam.unitedbloc.com:3000", "-p1454"])
    # end)
    # url = "http://localhost:1454"
    # url = "https://eu-d50f8756.dedicated-rpc-nodes.com/api/test123"
    # url = "https://moonbeam.api.onfinality.io/rpc?apikey=49e8baf7-14c3-4d0f-916a-94abf1c4c14a"
    url = "https://rpc.api.moonbeam.network"
    {:ok, trace} = RemoteChain.HTTP.rpc(url, "debug_traceTransaction", [tx_hash])
    trace
  end
end
