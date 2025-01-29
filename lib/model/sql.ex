# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Model.Sql do
  require Logger
  use Supervisor

  defp map_mod(ref) when is_reference(ref), do: ref
  defp map_mod(Model.CredSql), do: :persistent_term.get(Db.Creds)
  defp map_mod(_), do: :persistent_term.get(Db.Tickets)

  def start_link() do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  defmodule Init do
    use GenServer

    def start_link(_args) do
      GenServer.start_link(__MODULE__, [], name: __MODULE__)
    end

    @impl true
    def init(_args) do
      Model.Ets.init(Diode)
      Model.TicketSql.init()
      Model.KademliaSql.init()
      {:ok, :done}
    end
  end

  def init(_args) do
    File.mkdir(Diode.data_dir())
    start_database(Db.Tickets, "tickets.sq3")
    start_database(Db.Creds, "wallet.sq3")
    children = [Model.CredSql, Init]
    Supervisor.init(children, strategy: :one_for_one)
  end

  def start_database(atom, file) do
    path = Diode.data_dir(file)
    Logger.info("Opening #{path}")
    {:ok, conn} = Exqlite.Sqlite3.open(path)
    :persistent_term.put(atom, conn)
    query!(conn, "PRAGMA journal_mode = WAL")
    query!(conn, "PRAGMA synchronous = NORMAL")
  end

  def query(mod, sql, params \\ []) do
    conn = map_mod(mod)

    Stats.tc(:query, fn ->
      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
      :ok = Exqlite.Sqlite3.bind(stmt, params)
      ret = collect(conn, stmt, []) |> Enum.reverse()
      :ok = Exqlite.Sqlite3.release(conn, stmt)
      {:ok, ret}
    end)
  end

  defp collect(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> collect(conn, stmt, [row | acc])
      :done -> acc
    end
  end

  def query!(mod, sql, params \\ []) do
    {:ok, ret} = query(mod, sql, params)
    ret
  end

  def fetch!(mod, sql, param1) do
    case lookup!(mod, sql, param1) do
      nil -> nil
      binary -> BertInt.decode!(binary)
    end
  end

  def lookup!(mod, sql, param1 \\ [], default \\ nil) do
    case query!(mod, sql, List.wrap(param1)) do
      [] -> default
      [[value]] -> value
    end
  end
end
