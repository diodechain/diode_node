# Diode Server
# Copyright 2021-2025 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.PeerReadyEts do
  @moduledoc false
  @table :peer_ready_connections

  def reset do
    case :ets.info(@table) do
      :undefined -> :ok
      _ -> :ets.delete(@table)
    end

    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
  end

  def insert(address, pid) when is_binary(address) and is_pid(pid) do
    :ets.insert(@table, {address, pid})
  end

  def delete(address) when is_binary(address) do
    :ets.delete(@table, address)
  end

  def read do
    @table
    |> :ets.tab2list()
    |> Enum.filter(fn {_address, pid} -> Process.alive?(pid) end)
    |> Map.new()
  end
end
