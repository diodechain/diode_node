# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule KademliaSearch do
  @moduledoc """
    A @alpha multi-threaded kademlia search. Starts a master as well as @alpha workers
    and executed the specified cmd query in the network.
  """
  alias DiodeClient.Object
  use GenServer
  require Logger

  @max_oid 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF + 1
  @alpha 3

  @enforce_keys [:module]
  defstruct module: nil,
            tasks: [],
            from: nil,
            key: nil,
            queryable: nil,
            k: nil,
            visited: %{},
            waiting: [],
            queried: %{},
            cmd: nil,
            best: nil,
            finisher: nil

  def init(module) do
    :erlang.process_flag(:trap_exit, true)
    {:ok, %KademliaSearch{module: module}}
  end

  def find_nodes(module, key, nearest, k, cmd) do
    {:ok, pid} = GenServer.start_link(__MODULE__, module)
    GenServer.call(pid, {:find_nodes, key, nearest, k, cmd}, 20_000)
  end

  def handle_call({:find_nodes, key, nearest, k, cmd}, from, state) do
    state = %KademliaSearch{
      state
      | from: from,
        key: key,
        queryable: KBuckets.to_map(nearest),
        k: k,
        cmd: cmd
    }

    tasks = for _ <- 1..@alpha, do: start_worker(state)
    {:noreply, %{state | tasks: tasks}}
  end

  def handle_info({:EXIT, worker_pid, reason}, state = %KademliaSearch{tasks: tasks}) do
    Logger.info("#{__MODULE__} received :EXIT #{inspect(reason)}")
    tasks = Enum.reject(tasks, fn pid -> pid == worker_pid end)
    tasks = [start_worker(state) | tasks]
    {:noreply, %KademliaSearch{state | tasks: tasks}}
  end

  def handle_info(:finish, %KademliaSearch{
        visited: visited,
        queried: queried,
        from: from,
        best: value,
        tasks: tasks,
        key: key
      }) do
    ret =
      Map.merge(visited, queried)
      |> Enum.sort_by(fn {node_key, _node} -> KBuckets.distance(key, node_key) end)
      |> Enum.map(fn {_node_key, node} -> node end)

    if value != nil do
      GenServer.reply(from, {:value, value, ret})
    else
      GenServer.reply(from, ret)
    end

    Enum.each(tasks, fn task -> send(task, :done) end)
    {:stop, :normal, nil}
  end

  def handle_info(
        {:kadret, {:value, value}, node, task},
        state = %KademliaSearch{best: best, finisher: fin}
      ) do
    # IO.puts("Found #{inspect(value)} on node #{inspect (node)}")

    obj_block_num =
      Object.decode!(value)
      |> Object.block_number()

    fin =
      with nil <- fin do
        :timer.send_after(200, :finish)
      end

    best =
      if best != nil and
           Object.block_number(Object.decode!(best)) >
             obj_block_num do
        best
      else
        value
      end

    handle_info({:kadret, [], node, task}, %KademliaSearch{state | best: best, finisher: fin})
  end

  def handle_info(
        {:kadret, nodes, node, task},
        state = %KademliaSearch{
          visited: visited,
          waiting: waiting,
          key: key,
          queried: queried,
          queryable: queryable,
          finisher: finisher
        }
      ) do
    waiting = [task | waiting]
    # not sure
    visited =
      if node == nil do
        visited
      else
        Map.put(visited, KBuckets.key(node), node)
      end

    # Visit at least k nodes, and ensure those are the nearest
    # k nodes to the key
    min_distance =
      if map_size(visited) < state.k do
        @max_oid
      else
        Enum.map(visited, fn {node_key, _node} -> KBuckets.distance(key, node_key) end)
        |> Enum.sort()
        |> Enum.at(state.k - 1)
      end

    # only those that are nearer
    queryable =
      Map.merge(queryable, KBuckets.to_map(nodes))
      |> Enum.map(fn {node_key, node} -> {KBuckets.distance(key, node_key), node_key, node} end)
      |> Enum.filter(fn {distance, node_key, _node} ->
        Map.has_key?(queried, node_key) == false and distance < min_distance
      end)
      |> Enum.sort()
      |> Enum.take(state.k)
      |> Enum.map(fn {_distance, node_key, node} -> {node_key, node} end)

    sends = min(length(queryable), length(waiting))
    {nexts, queryable} = Enum.split(queryable, sends)
    {nexts, queryable} = {Map.new(nexts), Map.new(queryable)}
    {pids, waiting} = Enum.split(waiting, sends)

    for {next, pid} <- Enum.zip(Map.values(nexts), pids) do
      send(pid, {:next, next})
    end

    state = %KademliaSearch{
      state
      | queryable: queryable,
        visited: visited,
        waiting: waiting,
        queried: Map.merge(queried, nexts)
    }

    if map_size(queryable) == 0 and length(waiting) == @alpha and finisher == nil do
      handle_info(:finish, state)
    else
      {:noreply, state}
    end
  end

  defp start_worker(%KademliaSearch{module: module, key: key, cmd: cmd}) do
    spawn_link(__MODULE__, :worker_loop, [module, nil, key, self(), cmd])
  end

  def worker_loop(module, node, key, father, cmd) do
    ret =
      if node == nil,
        do: [],
        else:
          module.rpc(node, [cmd, key])
          |> import_network_items()

    send(father, {:kadret, ret, node, self()})

    receive do
      {:next, node} -> worker_loop(module, node, key, father, cmd)
      :done -> :ok
    end
  end

  defp import_network_items(items) when is_list(items) do
    Enum.map(items, &import_network_item/1)
  end

  defp import_network_items(result) when is_tuple(result) do
    result
  end

  defp import_network_item(%{node_id: node_id, object: object}) do
    Model.KademliaSql.maybe_update_object(nil, object)

    %KBuckets.Item{
      node_id: node_id
    }
  end
end
