# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Model.CredSql do
  alias Model.Sql
  alias DiodeClient.{Wallet, Secp256k1}
  use GenServer
  require Logger

  require Record
  Record.defrecord(:key_value, key: nil, value: nil)

  @spec start_link([]) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link([]) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  defp query!(sql, params \\ []) do
    Sql.query!(__MODULE__, sql, params)
  end

  def init(_args) do
    query!("""
        CREATE TABLE IF NOT EXISTS config (
          key TEXT PRIMARY KEY,
          value BLOB
        )
    """)

    case Diode.Config.get_int("PRIVATE") do
      # Decode env parameter such as
      # export PRIVATE="0x123456789"
      0 ->
        :ok

      private ->
        :binary.encode_unsigned(private)
        |> Wallet.from_privkey()
        |> set_wallet()
    end

    Diode.puts("====== Coinbase ======")
    Diode.puts("#{Wallet.printable(Diode.wallet())}")
    Diode.puts("")

    {:ok, %{}}
  end

  defp ensure_identity() do
    case :persistent_term.get(:identity, nil) do
      nil ->
        id = ensure_config("identity", fn -> Secp256k1.generate() end)
        :persistent_term.put(:identity, id)
        id

      id ->
        id
    end
  end

  def put_config(key, value) when is_binary(key) do
    value_data = BertInt.encode!(value)
    query!("REPLACE INTO config (key, value) VALUES(?1, ?2)", [key, value_data])
    value
  end

  def config(key) when is_binary(key) do
    Sql.fetch!(__MODULE__, "SELECT value FROM config WHERE key = ?1", key)
  end

  def ensure_config(key, fallback) do
    case config(key) do
      nil -> put_config(key, fallback.())
      other -> other
    end
  end

  def set_wallet(wallet) do
    id = {Wallet.pubkey!(wallet), Wallet.privkey!(wallet)}
    put_config("identity", id)
    :persistent_term.put(:identity, id)
  end

  def wallet() do
    {_public, private} = ensure_identity()
    Wallet.from_privkey(private)
  end

  def handle_info({:nodeup, node}, state) do
    Logger.warning("Node #{inspect(node)} UP")
    {:noreply, state}
  end

  def handle_info({:nodedown, node}, state) do
    Logger.warning("Node #{inspect(node)} DOWN")
    {:noreply, state}
  end
end
