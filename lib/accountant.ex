defmodule Diode.Accountant do
  require Logger

  def address() do
    case Diode.Config.get("ACCOUNTANT_ADDRESS") do
      nil ->
        nil

      "0x" <> hex ->
        case Base.decode16(hex, case: :mixed) do
          {:ok, addr} when byte_size(addr) == 20 -> addr
          _other -> nil
        end

      _other ->
        nil
    end
  end

  def set_address("0x" <> hex = address) do
    Logger.info("Setting accountant address to #{inspect(address)}")

    case Base.decode16(hex, case: :mixed) do
      {:ok, address} when byte_size(address) == 20 ->
        Contract.NodeRegistry.register_node_transaction(address, 0)
        |> Contract.NodeRegistry.execute()

      _other ->
        {:error, "Invalid accountant address #{inspect(hex)}"}
    end
  end
end
