# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule RpcTest do
  use ExUnit.Case, async: false
  import TestHelper
  alias Chain.Transaction
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

    assert {200,
            %{
              "id" => 1,
              "jsonrpc" => "2.0",
              "result" => %{
                "blockNumber" => "0x3",
                "contractAddress" => nil,
                "cumulativeGasUsed" => _variable,
                "from" => ^from,
                "gasUsed" => "0x5208",
                "logs" => [],
                "logsBloom" =>
                  "0x0000000000000000000000000000000000000000000000000000000000000000",
                "status" => "0x1",
                "to" => ^to,
                "transactionHash" => ^hash,
                "transactionIndex" => "0x0"
              }
            }} = ret
  end

  test "getblock" do
    tx = prepare_transaction()
    hash = Transaction.hash(tx) |> Base16.encode()
    ret = rpc("eth_getBlockByNumber", [peaknumber(), false])

    assert {200,
            %{
              "id" => 1,
              "jsonrpc" => "2.0",
              "result" => %{
                "transactions" => txs
              }
            }} = ret

    assert Enum.member?(txs, hash)
  end

  defp to_rlp(tx) do
    tx |> Transaction.to_rlp() |> Rlp.encode!() |> Base16.encode()
  end

  defp prepare_transaction() do
    [from, to] = Diode.wallets() |> Enum.reverse() |> Enum.take(2)
    # Worker.set_mode(:disabled)

    tx =
      Rpc.create_transaction(from, <<"">>, %{
        "value" => 1000,
        "to" => Wallet.address!(to),
        "gasPrice" => 0
      })

    {200, %{"result" => txhash}} = rpc("eth_sendRawTransaction", [to_rlp(tx)])
    assert txhash == Base16.encode(Transaction.hash(tx))

    # Worker.set_mode(:poll)
    tx
  end

  def rpc(method, params) do
    Chain.RPC.rpc(chain(), method, params)
  end
end
