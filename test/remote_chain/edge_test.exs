# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule RemoteChain.EdgeTest do
  use ExUnit.Case, async: true
  alias RemoteChain.Edge

  describe "decode_header_field!/4" do
    test "raises descriptive error when a required block header field is nil" do
      assert_raise RuntimeError,
                   "block header field transactionsRoot is nil for chain glmr block 12345",
                   fn ->
                     Edge.decode_header_field!(Chains.Moonbeam, 12_345, "transactionsRoot", nil)
                   end
    end

    test "decodes a hex field when present" do
      assert Edge.decode_header_field!(Chains.Diode, 1, "hash", "0x01") == <<1>>
    end
  end

  describe "decode_header_int!/4" do
    test "raises descriptive error when a required block header integer field is nil" do
      assert_raise RuntimeError,
                   "block header field timestamp is nil for chain sapphire block 99",
                   fn ->
                     Edge.decode_header_int!(Chains.OasisSapphire, 99, "timestamp", nil)
                   end
    end
  end
end
