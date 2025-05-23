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
            visited: [],
            waiting: [],
            queried: [],
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
    state = %KademliaSearch{state | from: from, key: key, queryable: nearest, k: k, cmd: cmd}

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
      KBuckets.unique(visited ++ queried)
      |> Enum.sort_by(fn node -> KBuckets.distance(key, node) end)

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
        KBuckets.unique(visited ++ [node])
      end

    # Visit at least k nodes, and ensure those are the nearest
    # k nodes to the key
    min_distance =
      if length(visited) < state.k do
        @max_oid
      else
        Enum.sort_by(visited, fn node -> KBuckets.distance(key, node) end)
        |> Enum.at(state.k - 1)
        |> KBuckets.distance(key)
      end

    # only those that are nearer
    queryable =
      KBuckets.unique(queryable ++ nodes)
      |> Enum.filter(fn node ->
        KBuckets.distance(key, node) < min_distance and
          KBuckets.member?(queried, node) == false
      end)
      |> KBuckets.nearest_n(state.key, state.k)

    sends = min(length(queryable), length(waiting))
    {nexts, queryable} = Enum.split(queryable, sends)
    {pids, waiting} = Enum.split(waiting, sends)
    Enum.zip(nexts, pids) |> Enum.each(fn {next, pid} -> send(pid, {:next, next}) end)
    queried = queried ++ nexts

    state = %KademliaSearch{
      state
      | queryable: queryable,
        visited: visited,
        waiting: waiting,
        queried: queried
    }

    if queryable == [] and length(waiting) == @alpha and finisher == nil do
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
