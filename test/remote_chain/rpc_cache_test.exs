# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule RemoteChain.RPCCacheTest do
  use ExUnit.Case, async: true

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
end
