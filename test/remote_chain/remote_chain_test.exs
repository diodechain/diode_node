# Diode Server
# Copyright 2021-2026 Diode
# Licensed under the Diode License, Version 1.1

defmodule RemoteChainTest do
  use ExUnit.Case, async: true

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
end
