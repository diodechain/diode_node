# Diode Server
# Copyright 2021-2026 Diode
# Licensed under the Diode License, Version 1.1

defmodule RemoteChain.RPCTest do
  use ExUnit.Case, async: true

  alias RemoteChain.RPC

  describe "decode_rpc_response/1" do
    test "unwraps standard result and error envelopes" do
      assert {:ok, "0x1"} = RPC.decode_rpc_response(%{"jsonrpc" => "2.0", "result" => "0x1"})

      assert {:error, %{"code" => -32000, "message" => "execution reverted"}} =
               RPC.decode_rpc_response(%{
                 "jsonrpc" => "2.0",
                 "error" => %{"code" => -32000, "message" => "execution reverted"}
               })
    end

    test "treats flat Hardhat/Ganache-style error envelopes as errors (bns.exs regression)" do
      # Production crash: rpc_with_retry had no clause for providers that put
      # code/message/data on the JSON-RPC envelope instead of under "error".
      flat = %{
        "code" => -32000,
        "data" => %{
          "0xaf2b464fc5af9e2d78130815b10d050d7d91620f43059850df2ebb7c68e51739" => %{
            "error" => "revert",
            "reason" => "0x",
            "return" => "0x"
          }
        },
        "id" => 8095,
        "jsonrpc" => "2.0",
        "message" => "VM Exception while processing transaction: revert "
      }

      assert {:error, ^flat} = RPC.decode_rpc_response(flat)
    end

    test "passes through disconnect and other unexpected replies" do
      assert {:error, :disconnect} = RPC.decode_rpc_response({:error, :disconnect})
      assert {:error, :timeout} = RPC.decode_rpc_response({:error, :timeout})
      assert {:error, "weird"} = RPC.decode_rpc_response("weird")
    end
  end

  describe "send_raw_transaction/2 Moonbeam rejection" do
    test "rejects Moonbeam submits as transaction_rejected without contacting RPC" do
      assert {:error, :transaction_rejected} =
               RPC.send_raw_transaction(Chains.Moonbeam, "0xdead")
    end
  end
end
