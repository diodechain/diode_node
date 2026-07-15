# Diode Server
# Copyright 2021-2025 Diode
# Licensed under the Diode License, Version 1.1
defmodule Chains.BaseTest do
  use ExUnit.Case, async: true

  test "Chains.Base chain metadata" do
    assert Chains.Base.chain_id() == 8453
    assert Chains.Base.expected_block_intervall() == 2
    assert Chains.Base.chain_prefix() == "base"
    assert RemoteChain.chainimpl(Chains.Base) == Chains.Base
  end

  test "Chains.Base exposes contract addresses" do
    assert byte_size(Chains.Base.registry_address()) == 20
    assert byte_size(Chains.Base.developer_fleet_address()) == 20
  end
end
