# Diode Server
# Copyright 2021-2026 Diode
# Licensed under the Diode License, Version 1.1

defmodule RemoteChainTest do
  use ExUnit.Case, async: false

  describe "accepts_transactions?/1" do
    test "returns false for Moonbeam (module, chain id, and prefix)" do
      refute RemoteChain.accepts_transactions?(Chains.Moonbeam)
      refute RemoteChain.accepts_transactions?(Chains.Moonbeam.chain_id())
      refute RemoteChain.accepts_transactions?("glmr")
    end

    test "returns true for other configured chains" do
      assert RemoteChain.accepts_transactions?(Chains.Diode)
      assert RemoteChain.accepts_transactions?(Chains.OasisSapphire)
      assert RemoteChain.accepts_transactions?(Chains.Base)
    end
  end

  describe "ws_endpoints/1 env override" do
    @env_key "CHAINS_DIODE_WS"

    setup do
      prev = System.get_env(@env_key)

      on_exit(fn ->
        if prev, do: System.put_env(@env_key, prev), else: System.delete_env(@env_key)
      end)

      :ok
    end

    test "bang prefix replaces ChainImpl defaults" do
      System.put_env(@env_key, "!ws://local-override.example/ws")
      assert RemoteChain.ws_endpoints(Chains.Diode) == ["ws://local-override.example/ws"]
    end

    test "bare value replaces ChainImpl defaults" do
      System.put_env(@env_key, "ws://bare-override.example/ws")
      assert RemoteChain.ws_endpoints(Chains.Diode) == ["ws://bare-override.example/ws"]
    end

    test "plus prefix prepends to ChainImpl defaults" do
      System.put_env(@env_key, "+ws://extra.example/ws")
      result = RemoteChain.ws_endpoints(Chains.Diode)
      assert hd(result) == "ws://extra.example/ws"
      assert Chains.Diode.ws_endpoints() -- result == []
    end

    test "unset env uses ChainImpl list" do
      System.delete_env(@env_key)
      assert RemoteChain.ws_endpoints(Chains.Diode) == Chains.Diode.ws_endpoints()
    end
  end

  describe "rpc_endpoints/1 env override" do
    @env_key "CHAINS_DIODE_RPC"

    setup do
      prev = System.get_env(@env_key)

      on_exit(fn ->
        if prev, do: System.put_env(@env_key, prev), else: System.delete_env(@env_key)
      end)

      :ok
    end

    test "bang prefix replaces ChainImpl rpc defaults" do
      System.put_env(@env_key, "!http://local-override.example:3834")
      assert RemoteChain.rpc_endpoints(Chains.Diode) == ["http://local-override.example:3834"]
    end
  end

  describe "frozen?/1" do
    test "returns true for chains that opt in via frozen?/0 (Moonbeam)" do
      assert RemoteChain.frozen?(Chains.Moonbeam)
    end

    test "returns false for chains that do not declare frozen?/0" do
      refute RemoteChain.frozen?(Chains.Diode)
      refute RemoteChain.frozen?(Chains.OasisSapphire)
      refute RemoteChain.frozen?(Chains.Base)
    end

    test "accepts chain_id and chain prefix dispatch" do
      assert RemoteChain.frozen?(Chains.Moonbeam.chain_id())
      assert RemoteChain.frozen?("glmr")
    end
  end

  describe "final_block_number/1" do
    test "returns the chain's declared final block number (Moonbeam)" do
      assert is_integer(RemoteChain.final_block_number(Chains.Moonbeam))

      assert RemoteChain.final_block_number(Chains.Moonbeam) ==
               Chains.Moonbeam.final_block_number()
    end

    test "returns nil for chains that have not declared final_block_number/0" do
      assert RemoteChain.final_block_number(Chains.Diode) == nil
      assert RemoteChain.final_block_number(Chains.OasisSapphire) == nil
      assert RemoteChain.final_block_number(Chains.Base) == nil
    end
  end
end
