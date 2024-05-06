# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule RpcTest do
  use ExUnit.Case, async: false
  import TestHelper
  alias RemoteChain.Transaction
  alias Network.Rpc

  setup_all do
    TestHelper.reset()
  end

  test "eth_getBlockByNumber" do
    {:ok, %{}} = rpc("eth_getBlockByNumber", [0, false])
    {:ok, nil} = rpc("eth_getBlockByNumber", [1, false])
    {:ok, nil} = rpc("eth_getBlockByNumber", [150, false])
    {:ok, %{}} = rpc("eth_getBlockByNumber", ["earliest", false])
    {:ok, %{}} = rpc("eth_getBlockByNumber", ["latest", false])
  end

  test "receipt" do
    tx = prepare_transaction()

    hash = Transaction.hash(tx) |> Base16.encode()
    from = Transaction.from(tx) |> Base16.encode()
    to = Transaction.to(tx) |> Base16.encode()

    ret = rpc("eth_getTransactionReceipt", [hash])
    blocknumber = "0x#{peaknumber()}"

    assert {:ok,
            %{
              "blockNumber" => ^blocknumber,
              "contractAddress" => nil,
              "cumulativeGasUsed" => _variable,
              "from" => ^from,
              "gasUsed" => "0x5208",
              "logs" => [],
              "logsBloom" =>
                "0x0000000000000000000000000000000000000000000000000000000000000000" <> _,
              "status" => "0x1",
              "to" => ^to,
              "transactionHash" => ^hash,
              "transactionIndex" => "0x0"
            }} = ret
  end

  test "getblock" do
    current = peaknumber()
    tx = prepare_transaction()
    hash = Transaction.hash(tx) |> Base16.encode()
    {:ok, next} = rpc("eth_blockNumber", [])
    next = Base16.decode_int(next)

    assert Enum.find(current..next, fn n ->
             ret = rpc("eth_getBlockByNumber", [n, false])
             {:ok, %{"transactions" => txs}} = ret
             Enum.member?(txs, hash)
           end)
  end

  defp to_rlp(tx) do
    tx |> Transaction.to_rlp() |> Rlp.encode!() |> Base16.encode()
  end

  defp prepare_transaction() do
    [from, to] = Diode.wallets() |> Enum.reverse() |> Enum.take(2)

    price =
      RemoteChain.RPC.gas_price(chain())
      |> Base16.decode_int()

    nonce =
      RemoteChain.RPC.get_transaction_count(chain(), Base16.encode(Wallet.address!(from)))
      |> Base16.decode_int()

    tx =
      Rpc.create_transaction(from, <<"">>, %{
        "value" => 1000,
        "to" => Wallet.address!(to),
        "gasPrice" => price,
        "chainId" => chain().chain_id(),
        "nonce" => nonce
      })

    {:ok, txhash} = rpc("eth_sendRawTransaction", [to_rlp(tx)])
    assert txhash == Base16.encode(Transaction.hash(tx))
    RemoteChain.RPC.rpc!(Chains.Anvil, "evm_mine")

    tx
  end

  def rpc(method, params) do
    RemoteChain.RPC.rpc(chain(), method, params)
  end
end
