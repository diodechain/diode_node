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
end
