# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Model.Sql do
  # Automatically defines child_spec/1
  use Supervisor
  # esqlite doesn't support :infinity
  # @infinity 300_000_000

  defp databases() do
    [
      {Db.Tickets, "tickets.sq3"},
      {Db.Creds, "wallet.sq3"}
    ]
  end

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

    for {atom, file} <- databases() do
      start_database(atom, file)
    end

    children = [Model.CredSql, Init]
    Supervisor.init(children, strategy: :one_for_one)
  end

  def start_database(atom, file) do
    path = Diode.data_dir(file)
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
