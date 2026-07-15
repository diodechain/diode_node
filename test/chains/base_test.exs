# Diode Server
# Copyright 2021-2025 Diode
# Licensed under the Diode License, Version 1.1
defmodule Chains.BaseTest do
  use ExUnit.Case, async: true

  alias DiodeClient.{Base16, Shell.Base, Shell.Moonbeam}

  test "Chains.Base uses Base L2 chain metadata" do
    assert Chains.Base.chain_id() == Base.chain_id()
    assert Chains.Base.expected_block_intervall() == Base.block_time()
    assert Chains.Base.chain_prefix() == "base"
  end

  test "Chains.Base exposes registry and developer fleet addresses" do
    assert Chains.Base.registry_address() ==
             Base16.decode("0xfbfAF5BfF947869490C05d949c1BA5e260D6bd6E")

    assert Chains.Base.developer_fleet_address() ==
             Base16.decode("0x5c6ED819886b77017baAf81ef0E7abEAcb17bD1D")
  end

  test "Contract.NodeRegistry targets Moonbeam" do
    assert Contract.NodeRegistry.chain_id() == Moonbeam.chain_id()
  end
end
