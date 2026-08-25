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

  describe "inject_block_header/4" do
    defp full_header do
      %{
        "hash" => "0x1111111111111111111111111111111111111111111111111111111111111111",
        "nonce" => "0x0000000000000000",
        "miner" => "0x2222222222222222222222222222222222222222",
        "number" => "0x64",
        "parentHash" => "0x3333333333333333333333333333333333333333333333333333333333333333",
        "stateRoot" => "0x4444444444444444444444444444444444444444444444444444444444444444",
        "timestamp" => "0x66b3d350",
        "transactionsRoot" => "0x5555555555555555555555555555555555555555555555555555555555555555"
      }
    end

    defp block_key(chain, hex_block) do
      RemoteChain.RPCCache.cache_key(chain, "eth_getBlockByNumber", [hex_block, false])
    end

    test "stores the announced header under the eth_getBlockByNumber cache key" do
      cache = Lru.new(10)

      cache = RemoteChain.RPCCache.inject_block_header(cache, Chains.Anvil, 100, full_header())

      assert %{"result" => block} = RemoteChain.Cache.get(cache, block_key(Chains.Anvil, "0x64"))
      assert block["hash"] == full_header()["hash"]
      # Shape parity with eth_getBlockByNumber(n, false) responses.
      assert block["transactions"] == []
      assert block["uncles"] == []
    end

    test "keeps transactions/uncles when the provider includes them" do
      cache = Lru.new(10)
      header = Map.merge(full_header(), %{"transactions" => ["0xtx"], "uncles" => ["0xu"]})

      cache = RemoteChain.RPCCache.inject_block_header(cache, Chains.Anvil, 100, header)

      assert %{"result" => block} = RemoteChain.Cache.get(cache, block_key(Chains.Anvil, "0x64"))
      assert block["transactions"] == ["0xtx"]
      assert block["uncles"] == ["0xu"]
    end

    test "skips nil headers (number-only announcements)" do
      cache = Lru.new(10)
      cache = RemoteChain.RPCCache.inject_block_header(cache, Chains.Anvil, 100, nil)
      assert RemoteChain.Cache.get(cache, block_key(Chains.Anvil, "0x64")) == nil
    end

    test "skips headers missing a required field" do
      cache = Lru.new(10)
      header = Map.delete(full_header(), "stateRoot")

      cache = RemoteChain.RPCCache.inject_block_header(cache, Chains.Anvil, 100, header)

      assert RemoteChain.Cache.get(cache, block_key(Chains.Anvil, "0x64")) == nil
    end

    test "skips headers whose number does not match the announced block" do
      cache = Lru.new(10)

      cache = RemoteChain.RPCCache.inject_block_header(cache, Chains.Anvil, 101, full_header())

      assert RemoteChain.Cache.get(cache, block_key(Chains.Anvil, "0x64")) == nil
    end

    test "requires minerSignature for diode chains" do
      cache = Lru.new(10)

      cache = RemoteChain.RPCCache.inject_block_header(cache, Chains.Diode, 100, full_header())
      assert RemoteChain.Cache.get(cache, block_key(Chains.Diode, "0x64")) == nil

      header = Map.put(full_header(), "minerSignature", "0xabc")
      cache = RemoteChain.RPCCache.inject_block_header(cache, Chains.Diode, 100, header)
      assert %{"result" => _} = RemoteChain.Cache.get(cache, block_key(Chains.Diode, "0x64"))
    end
  end

  describe "handle_info({{NodeProxy, _}, :block_number, n, header})" do
    setup do
      previous = RemoteChain.RPCCache.optimistic_caching?()
      RemoteChain.RPCCache.set_optimistic_caching(false)
      on_exit(fn -> RemoteChain.RPCCache.set_optimistic_caching(previous) end)
      :ok
    end

    test "primes the block cache from the NodeProxy notification" do
      # Regression for EdgeV2 crashes (MatchError in
      # RemoteChain.Edge.get_block_header/2): providers announce new blocks
      # via newHeads slightly before serving them over eth_getBlockByNumber.
      # The notification must prime the cache so subscriber fetches for the
      # just-announced block are cache hits and never observe a nil result.
      cache = Lru.new(10)
      {:ok, pid} = GenServer.start_link(RemoteChain.RPCCache, {Chains.Anvil, cache})

      header = %{
        "hash" => "0x1111111111111111111111111111111111111111111111111111111111111111",
        "nonce" => "0x0000000000000000",
        "miner" => "0x2222222222222222222222222222222222222222",
        "number" => "0x64",
        "parentHash" => "0x3333333333333333333333333333333333333333333333333333333333333333",
        "stateRoot" => "0x4444444444444444444444444444444444444444444444444444444444444444",
        "timestamp" => "0x66b3d350",
        "transactionsRoot" => "0x5555555555555555555555555555555555555555555555555555555555555555"
      }

      send(pid, {{RemoteChain.NodeProxy, Chains.Anvil}, :block_number, 100, header})

      state = :sys.get_state(pid)
      assert state.block_number == 100

      key = RemoteChain.RPCCache.cache_key(Chains.Anvil, "eth_getBlockByNumber", ["0x64", false])
      assert %{"result" => block} = RemoteChain.Cache.get(state.cache, key)
      assert block["hash"] == header["hash"]
      assert block["transactions"] == []
    end

    test "still updates block_number when the header is nil" do
      cache = Lru.new(10)
      {:ok, pid} = GenServer.start_link(RemoteChain.RPCCache, {Chains.Anvil, cache})

      send(pid, {{RemoteChain.NodeProxy, Chains.Anvil}, :block_number, 100, nil})

      state = :sys.get_state(pid)
      assert state.block_number == 100

      key = RemoteChain.RPCCache.cache_key(Chains.Anvil, "eth_getBlockByNumber", ["0x64", false])
      assert RemoteChain.Cache.get(state.cache, key) == nil
    end
  end
end
