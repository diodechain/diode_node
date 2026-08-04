# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule RemoteChain.RPCCacheTest do
  use ExUnit.Case, async: false

  describe "normalize_args/3 for eth_getStorageAt" do
    test "uses short QUANTITY block encoding (Base rejects padded hex like 0x02f1cf00)" do
      # get_storage_many batch_call skips rpc/3; it must still run normalize_args.
      address = "0xda92764bb12e91010d132bcdd8e4a0270ee25fc9"
      slot = "0xc9f6766ee659edc5eddd04b71e82c56aa865e95b4ae66f7ebe9a16071844b44a"

      assert RemoteChain.RPCCache.normalize_args(Chains.Anvil, "eth_getStorageAt", [
               address,
               slot,
               49_401_600
             ]) == [address, slot, "0x2f1cf00"]
    end
  end

  describe "cache_key/3" do
    test "normalizes module, chain_id, and prefix to the same key" do
      params = ["0x2f313e4", false]
      method = "eth_getBlockByNumber"

      expected = {Chains.Anvil, method, params}

      assert RemoteChain.RPCCache.cache_key(Chains.Anvil, method, params) == expected

      assert RemoteChain.RPCCache.cache_key(Chains.Anvil.chain_id(), method, params) ==
               expected

      assert RemoteChain.RPCCache.cache_key(Chains.Anvil.chain_prefix(), method, params) ==
               expected
    end
  end

  describe "schedule_refresh/4" do
    setup do
      previous = :persistent_term.get({RemoteChain.RPCCache, :refresh_debounce_ms}, :unset)
      RemoteChain.RPCCache.set_refresh_debounce_ms(50)

      on_exit(fn ->
        case previous do
          :unset -> :persistent_term.erase({RemoteChain.RPCCache, :refresh_debounce_ms})
          ms -> RemoteChain.RPCCache.set_refresh_debounce_ms(ms)
        end
      end)

      :ok
    end

    test "debounces refresh to one execution per window under burst load" do
      parent = self()
      ref = make_ref()
      params = ["0x#{System.unique_integer([:positive])}", false]

      fun = fn -> send(parent, {:refreshed, ref}) end

      for _ <- 1..20 do
        RemoteChain.RPCCache.schedule_refresh(
          Chains.Anvil,
          "eth_getBlockByNumber",
          params,
          fun
        )
      end

      assert_receive {:refreshed, ^ref}, 200
      refute_receive {:refreshed, ^ref}, 80
    end

    test "allows another refresh after the debounce window" do
      parent = self()
      ref = make_ref()
      params = ["0x#{System.unique_integer([:positive])}", false]
      fun = fn -> send(parent, {:refreshed, ref}) end

      RemoteChain.RPCCache.schedule_refresh(Chains.Anvil, "eth_getBlockByNumber", params, fun)
      assert_receive {:refreshed, ^ref}, 200

      Process.sleep(60)

      RemoteChain.RPCCache.schedule_refresh(Chains.Anvil, "eth_getBlockByNumber", params, fun)
      assert_receive {:refreshed, ^ref}, 200
    end
  end
end
