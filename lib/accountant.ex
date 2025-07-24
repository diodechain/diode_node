defmodule Diode.Accountant do
  require Logger

  def set_address(address) do
    Logger.info("Setting accountant address to #{address}")

    Contract.NodeRegistry.register_node_transaction(address, address, 0)
    |> Contract.NodeRegistry.execute()
  end
end
