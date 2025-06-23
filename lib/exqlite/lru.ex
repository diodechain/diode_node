# Diode Server
# Copyright 2021-2025 Diode
# Licensed under the Diode License, Version 1.1
defmodule Exqlite.LRU do
  require Logger
  use GenServer

  defstruct conn: nil, statements: %{}, max_items: 1_000_000

  def start_link(opts \\ []) do
    {file_path, _opts} = Keyword.pop!(opts, :file_path)
    max_items = Keyword.get(opts, :max_items, 1_000_000)
    GenServer.start_link(__MODULE__, {file_path, max_items}, name: __MODULE__)
  end

  def init({file_path, max_items}) do
    {:ok, conn} = Exqlite.Sqlite3.open(file_path)
    query(conn, "PRAGMA journal_mode = WAL")
    query(conn, "PRAGMA synchronous = NORMAL")

    query(conn, """
    CREATE TABLE IF NOT EXISTS cache (
      key BLOB PRIMARY KEY,
      value BLOB,
      lastAccess INT
    )
    """)

    query(conn, "CREATE INDEX IF NOT EXISTS lastAccess ON cache (lastAccess)")

    statements =
      Enum.map(statements(), fn {name, sql} ->
        {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
        {name, [stmt]}
      end)
      |> Map.new()

    {:ok, %__MODULE__{conn: conn, statements: statements, max_items: max_items}}
  end

  def get(key) do
    key = :erlang.term_to_binary(key)

    case query_prepared(:get, [now(), key]) do
      [[value]] -> :erlang.binary_to_term(value)
      [] -> nil
    end
  end

  def set(key, value) do
    key = :erlang.term_to_binary(key)
    query_prepared(:set, [key, :erlang.term_to_binary(value, [:compressed]), now()])
    value
  end

  def delete(key) do
    key = :erlang.term_to_binary(key)
    query_prepared(:delete, [key])
  end

  def clear() do
    query_prepared(:clear, [])
    query_prepared(:vacuum, [])
  end

  def cleanup_lru(max_items \\ nil) do
    query_prepared(:cleanupLru, [max_items || GenServer.call(__MODULE__, :max_items)])
  end

  defp now() do
    System.os_time(:second)
  end

  defp query(conn, sql) when is_binary(sql) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
    ret = collect(conn, stmt, []) |> Enum.reverse()
    :ok = Exqlite.Sqlite3.release(conn, stmt)
    {:ok, ret}
  end

  defp query_prepared(method, params) when is_atom(method) do
    {conn, stmt} = GenServer.call(__MODULE__, {:get, method})

    stmt =
      if stmt == nil do
        {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, statements()[method])
        stmt
      else
        stmt
      end

    :ok = apply(Exqlite.Sqlite3, :bind, [stmt, params])
    ret = collect(conn, stmt, []) |> Enum.reverse()
    :ok = GenServer.cast(__MODULE__, {:release, method, stmt})
    ret
  end

  def handle_call(:max_items, _from, state) do
    {:reply, state.max_items, state}
  end

  def handle_call({:get, method}, _from, state) do
    {stmt, statements} =
      case Map.get(state.statements, method) do
        [] ->
          {nil, state.statements}

        [stmt | rest] ->
          {stmt, Map.put(state.statements, method, rest)}
      end

    {:reply, {state.conn, stmt}, %{state | statements: statements}}
  end

  def handle_cast({:release, method, stmt}, state) do
    statements =
      Map.update!(state.statements, method, fn
        rest -> [stmt | rest]
      end)

    {:noreply, %{state | statements: statements}}
  end

  defp collect(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> collect(conn, stmt, [row | acc])
      :done -> acc
    end
  end

  defp statements() do
    %{
      get: """
      UPDATE OR IGNORE cache
      SET lastAccess = ?1
      WHERE key = ?2
      RETURNING value
      """,
      set: """
      INSERT OR REPLACE INTO cache
      (key, value, lastAccess) VALUES (?1, ?2, ?3)
      """,
      delete: """
      DELETE FROM cache WHERE key = ?1
      """,
      clear: """
      DELETE FROM cache
      """,
      vacuum: """
      VACUUM
      """,
      cleanupLru: """
      WITH lru AS (SELECT key FROM cache ORDER BY lastAccess DESC LIMIT -1 OFFSET ?1)
      DELETE FROM cache WHERE key IN lru
      """
    }
  end
end
