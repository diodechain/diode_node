defmodule Diode.Accountant do
  alias DiodeClient.Base16
  require Logger

  def config_address() do
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

  def contract_address() do
    Contract.NodeRegistry.node_info().accountant
  end

  def schedule_ensure_address() do
    Debouncer.apply({__MODULE__, :ensure_address, []}, 60_000)
  end

  def ensure_address() do
    ensure_address(config_address())
  end

  defp ensure_address(nil) do
    ensure_address(<<0::unsigned-size(160)>>)
  end

  defp ensure_address(address) do
    Logger.info("Setting accountant address to #{Base16.encode(address)}")
    balance = Contract.NodeRegistry.token_balance()
    info = Contract.NodeRegistry.node_info()

    cond do
      info.accountant != address ->
        Logger.info(
          "Accountant address is configured to #{Base16.encode(info.accountant)}, changing to #{Base16.encode(address)}"
        )

        register_node(address, balance)

      balance > 0 ->
        Logger.info(
          "Accountant address is correct, but additional balance #{balance} found, registering node."
        )

        register_node(address, balance)

      true ->
        Logger.info(
          "Accountant address is already configured to #{Base16.encode(address)}, nothing to do."
        )

        :ok
    end
  end

  defp register_node(address, balance) do
    with {:ok, _} <- ensure_token_allowance() do
      Contract.NodeRegistry.register_node_transaction(address, balance)
      |> Diode.Transaction.execute()
    end
  end

  def ensure_token_allowance() do
    max_uint256 = Contract.NodeRegistry.max_uint256()

    case Contract.NodeRegistry.token_allowance() do
      ^max_uint256 ->
        {:ok, "Token allowance is already set"}

      allowance ->
        Logger.info("Token allowance is #{allowance}, setting to #{max_uint256}")
        Contract.NodeRegistry.set_token_allowance()
    end
  end
end
