# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.Stats do
  @moduledoc """
  Network statistics for bandwidth usage.
  """
  use GenServer
  @ticks_per_second 10
  def init(_args) do
    :timer.send_interval(@ticks_per_second * 1000, :tick)
    {:ok, dets} = DetsPlus.open_file(__MODULE__.LRU, file: Diode.data_dir("network_stats.dets+"))
    lru = DetsPlus.LRU.new(dets, 1_000_000)
    :persistent_term.put(__MODULE__.LRU, lru)
    {:ok, %{counters: %{}, done_counters: %{}, lru: lru}}
  end

  def start_link() do
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
    from = from - rem(from, @ticks_per_second)
    to = max(to - rem(to, @ticks_per_second), from)
    stepping = max(stepping - rem(stepping, @ticks_per_second), 1)

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
      Map.put(state.counters, :devices, map_size(Network.Server.get_connections(Network.EdgeV2)))

    # Roll up the counters
    tick_time = System.system_time(:second)
    tick_time = tick_time - rem(tick_time, @ticks_per_second)
    DetsPlus.LRU.put(state.lru, tick_time, counters)
    {:noreply, %{state | done_counters: counters, counters: %{}}}
  end
end
