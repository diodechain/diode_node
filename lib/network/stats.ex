# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.Stats do
  @moduledoc """
  Network statistics for bandwidth usage.
  """
  use GenServer
  require Logger
  @seconds_per_tick 60
  def init(_args) do
    :timer.send_interval(@seconds_per_tick * 1000, :tick)

    opts = [
      file: Diode.data_dir("network_stats.dets+"),
      auto_save_memory: 100_000_000,
      page_cache_memory: 100_000_000,
      compressed: true
    ]

    {:ok, dets} =
      try do
        DetsPlus.open_file(__MODULE__.LRU, opts)
      rescue
        error ->
          Logger.error("Failed to open DetsPlus: #{inspect(error)}, retrying...")
          File.rm(Diode.data_dir("network_stats.dets+"))
          DetsPlus.open_file(__MODULE__.LRU, opts)
      end

    lru = DetsPlus.LRU.new(dets, 1_000_000)
    :persistent_term.put(__MODULE__.LRU, lru)
    {:ok, %{counters: %{}, done_counters: %{}, lru: lru}}
  end

  def start_link(_args) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__, hibernate_after: 5_000)
  end

  def incr(metric, value \\ 1) do
    GenServer.cast(__MODULE__, {:incr, [{metric, value}]})
  end

  def batch_incr(metrics) when is_map(metrics) or is_list(metrics) do
    GenServer.cast(__MODULE__, {:incr, metrics})
  end

  def get(metric, default \\ 0) do
    GenServer.call(__MODULE__, :get)
    |> Map.get(metric, default)
  end

  def get_history(from, to, stepping) do
    from = from - rem(from, @seconds_per_tick)
    to = max(to - rem(to, @seconds_per_tick), from)
    stepping = max(stepping - rem(stepping, @seconds_per_tick), 1)

    Range.new(from, to, stepping)
    |> Enum.map(&{&1, DetsPlus.LRU.get(:persistent_term.get(__MODULE__.LRU), &1)})
    |> Enum.filter(fn
      {_, nil} -> false
      _ -> true
    end)
    |> Map.new()
  end

  def handle_cast({:incr, metrics}, state) do
    counters =
      Enum.reduce(metrics, state.counters, fn {metric, value}, acc ->
        Map.update(acc, metric, value, fn i -> i + value end)
      end)

    {:noreply, %{state | counters: counters}}
  end

  def handle_call(:get, _from, state) do
    {:reply, state.done_counters, state}
  end

  def handle_info(:tick, state) do
    # Adding common network counters
    counters =
      state.counters
      |> Map.put(:devices, map_size(Network.Server.get_connections(Network.EdgeV2)))
      |> Map.put(:ticket_score, TicketStore.epoch_score())

    # Roll up the counters
    tick_time = System.system_time(:second)
    tick_time = tick_time - rem(tick_time, @seconds_per_tick)
    DetsPlus.LRU.put(state.lru, tick_time, counters)
    {:noreply, %{state | done_counters: counters, counters: %{}}}
  end
end
