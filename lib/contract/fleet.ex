# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Contract.Fleet do
  @moduledoc """
    Wrapper for the FleetRegistry contract functions
    as needed by the tests
  """

  alias DiodeClient.{Base16, Hash}

  def set_device_allowlist(chain_id, fleet, address, bool) when is_boolean(bool) do
    Shell.transaction(
      Diode.wallet(),
      fleet,
      "SetDeviceAllowlist",
      ["address", "bool"],
      [address, bool],
      chainId: chain_id
    )
  end

  def device_allowlisted?(chain_id, fleet, address) do
    ret = call(chain_id, fleet, "DeviceAllowlist", ["address"], [address], "latest")

    case :binary.decode_unsigned(ret) do
      1 -> true
      0 -> false
    end
  end

  def accountant(chain_id, fleet) do
    call(chain_id, fleet, "Accountant", [], [], "latest")
    |> Hash.to_address()
  end

  def operator(chain_id, fleet) do
    call(chain_id, fleet, "Operator", [], [], "latest")
    |> Hash.to_address()
  end

  defp call(chain_id, fleet, name, types, values, blockRef) do
    Shell.call(chain_id, fleet, name, types, values, blockRef: blockRef)
    |> Base16.decode()
  end
end
