# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule KademliaLight do
  @moduledoc """
  K* light-node DHT: geometric ring over on-chain NodeRegistry members,
  node metadata in SQLite, live connection state in ETS.

  Replication uses Dynamo-style quorum: N=3 replicas, W=2 writes, R=2 reads.
  Local node counts toward W and R. Correctness depends on reaching W/R peers
  among the same on-chain replica set, not on a fully connected mesh.
  """
  use GenServer
  alias KademliaLight.Node
  alias Network.PeerHandlerV2
  alias DiodeClient.{Base16, ETSLru, Object, Object.Server, Wallet}
  alias Model.KademliaSql
  require Logger

  @n 3
  @w 2
  @r 2
  @ets_table :kademlia_network
  @redistribute_interval :timer.minutes(2)
  @contact_interval :timer.minutes(1)
  @discover_batch 40
  @discover_throttle_seconds 3600
  @discover_throttle_table :kademlia_discover_throttle
  @max_retry_seconds 6 * 3600
  @fib_max_index 28
  @rpc_lookup_timeout 2000
  @rpc_read_timeout 800
  # Upper bound for GenServer.call to PeerHandler; avoids hung spawns if peer deadlocks.
  @rpc_peer_call_timeout 30_000

  defstruct ring: [], version: 3

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__, hibernate_after: 5_000)
  end

  def store(object) when is_tuple(object) do
    key = Object.key(object)
    value = Object.encode!(object)
    store(key, value)
  end

  def store(key, value) when is_binary(value) do
    hkey = hash(key)
    KademliaSql.maybe_update_object(hkey, value)
    quorum_store_remote(hkey, value, &rpc/2)
  end

  def find_value(key) do
    key = hash(key)

    result = get_cached(&do_find_value_quorum/1, {:find_value, key}, key)

    case result do
      {:value, value} ->
        value = merge_local_find_value(key, value)
        repair_replicas(key, value)
        value

      :miss ->
        case KademliaSql.object(key) do
          nil ->
            nil

          local_ret ->
            repair_replicas(key, local_ret)
            local_ret
        end

      _ ->
        nil
    end
  end

  def find_node_object(address) do
    if address == Diode.address() do
      Diode.self()
    end ||
      case find_nodes(address) do
        [] ->
          nil

        [first | _] ->
          case Wallet.address!(first.node_id) do
            ^address -> node_object(first)
            _ -> nil
          end
      end ||
      with binary when is_binary(binary) <- find_value(address) do
        Object.decode!(binary)
      end
  end

  def find_nodes(key) do
    key = hash(key)
    replica_hint_nodes(key)
  end

  def find_node_lookup(key) do
    key = hash(key)
    get_cached(&replica_hint_nodes/1, {:find_node_lookup, key}, key)
  end

  def network() do
    GenServer.call(__MODULE__, :network, 30_000)
  end

  def ring_nodes() do
    case :ets.lookup(@ets_table, :ring) do
      [{:ring, nodes}] -> nodes
      _ -> [Node.new(Diode.wallet())]
    end
  end

  def node_meta(address) do
    case :ets.lookup(@ets_table, address) do
      [{^address, meta}] -> meta
      _ -> KademliaSql.get_node(address)
    end
  end

  def register_node(node_id, server) do
    if Model.KademliaSql.maybe_update_object(nil, server) do
      address = Wallet.address!(node_id)
      KademliaSql.refresh_known_good(address)
      KademliaSql.upsert_node_from_connection(node_id, %{known_good: false})
      GenServer.cast(__MODULE__, {:register_node, node_id})
      :ok
    end
  end

  def drop_nodes(keys) when is_list(keys) do
    GenServer.call(__MODULE__, {:drop_nodes, keys}, 60_000)
  end

  def redistribute_removed_node(address) do
    Debouncer.apply(
      {:redistribute_removed, address},
      fn ->
        node = Node.new(Wallet.from_address(address))

        spawn(__MODULE__, :redistribute_stale, [
          ring_nodes(),
          node
        ])
      end,
      :timer.minutes(2)
    )
  end

  def reset() do
    GenServer.call(__MODULE__, :reset)
  end

  def append(key, value, store_self \\ false) do
    GenServer.call(__MODULE__, {:append, key, value, store_self})
  end

  @impl true
  def init(:ok) do
    :ets.new(@ets_table, [:named_table, :set, :public, read_concurrency: true])

    :ets.new(@discover_throttle_table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true
    ])

    ETSLru.new(__MODULE__, 2048, fn value ->
      case value do
        nil -> false
        [] -> false
        _ -> true
      end
    end)

    old_path = Diode.data_dir("kademlia_light.etf")

    if File.exists?(old_path) do
      Logger.info("Ignoring legacy kademlia_light.etf (network is registry-backed now)")
      File.rm(old_path)
    end

    ring = load_ring()
    write_ets_ring(ring)

    {:ok, %__MODULE__{ring: ring, version: 3}, {:continue, :bootstrap}}
  end

  @impl true
  def handle_continue(:bootstrap, state) do
    case KademliaSql.sync_registry_nodes() do
      :error -> KademliaSql.ensure_self_node_for_init()
      :ok -> :ok
    end

    ring = load_ring()
    write_ets_ring(ring)
    state = %{state | ring: ring}

    :timer.send_interval(@contact_interval, :contact_nodes)
    :timer.send_interval(@redistribute_interval, :scan_redistribution)

    {:noreply, _} = handle_info(:contact_nodes, state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:reset, _from, _state) do
    :ets.delete_all_objects(@ets_table)
    :ets.delete_all_objects(@discover_throttle_table)
    KademliaSql.clear_nodes()
    ring = [Node.new(Diode.wallet())]
    write_ets_ring(ring)
    {:reply, :ok, %__MODULE__{ring: ring}}
  end

  def handle_call({:drop_nodes, keys}, _from, state) do
    KademliaSql.delete_nodes_by_ring_keys(keys)
    ring = load_ring()
    write_ets_ring(ring)
    {:reply, :ok, %{state | ring: ring}}
  end

  def handle_call(:network, _from, state) do
    {:reply, state.ring, state}
  end

  def handle_call({:append, key, value, _store_self}, _from, state) do
    KademliaSql.append!(key, value)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(:reload_ring, state) do
    ring = load_ring()
    write_ets_ring(ring)
    {:noreply, %{state | ring: ring}}
  end

  def handle_cast({:register_node, node_id}, state) do
    KademliaSql.upsert_node_from_connection(node_id, %{known_good: false})
    ring = load_ring()
    write_ets_ring(ring)
    ensure_node_connection(Node.new(node_id))
    {:noreply, %{state | ring: ring}}
  end

  def handle_cast({:stable_node, node_id}, state) do
    KademliaSql.mark_stable(node_id)
    update_ets_meta(node_id)
    node = Node.new(node_id)
    queue_redistribute(node)
    {:noreply, state}
  end

  def handle_cast({:failed_node, node_id}, state) do
    next_retry = next_retry_at(KademliaSql.get_node(Wallet.address!(node_id)) || %{failures: 1})
    KademliaSql.mark_failed(node_id, next_retry)
    update_ets_meta(node_id)
    {:noreply, state}
  end

  @impl true
  def handle_info(:contact_nodes, state) do
    ring = state.ring

    spawn(fn ->
      found = discover_registry_objects(ring)
      missing = registry_nodes_missing_object(ring)

      if found > 0 or missing > 0 do
        Logger.info(
          "Registry discovery: found #{found} objects, #{missing} on-chain nodes still without endpoint"
        )
      end

      contact_registry_nodes(ring)
    end)

    contact_seed_nodes()
    {:noreply, state}
  end

  def handle_info(:scan_redistribution, state) do
    ready = Network.Server.get_ready_connections(PeerHandlerV2)

    for {address, _ring_key} <- KademliaSql.nodes_needing_redistribution() do
      if not Map.has_key?(ready, address) do
        node = Node.new(Wallet.from_address(address))

        Debouncer.apply(
          {:redistribute_stale, address},
          fn -> redistribute_stale(ring_nodes(), node) end,
          :timer.minutes(2)
        )
      end
    end

    {:noreply, state}
  end

  def update_stale_nodes(stale, network) do
    Process.register(self(), :stale_nodes_updater)
    Logger.info("Redistributing #{length(stale)} stale nodes")

    for stale_node <- stale do
      redistribute_stale(network, stale_node)
    end
  end

  def rpc(nodes, call) when is_list(nodes) do
    me = self()
    ref = make_ref()

    Enum.map(nodes, fn node ->
      spawn_link(fn ->
        send(me, {ref, rpc(node, call)})
      end)
    end)
    |> Enum.map(fn _pid ->
      receive do
        {^ref, ret} -> ret
      end
    end)
  end

  def rpc(%Node{node_id: node_id}, call) do
    address = Wallet.address!(node_id)

    case Map.get(ready_connections(), address) do
      nil ->
        []

      pid ->
        rpc_with_cutoff(node_id, pid, call)
    end
  end

  defp ready_connections do
    Network.Server.get_ready_connections(PeerHandlerV2)
  end

  defp rpc_with_cutoff(node_id, pid, call, timeout \\ @rpc_lookup_timeout) do
    parent = self()
    ref = make_ref()
    log_ref = make_ref()

    spawn(fn ->
      logger = spawn(fn -> log_rpc_after_cutoff(node_id, log_ref, timeout) end)

      t0 = System.monotonic_time(:millisecond)
      result = rpc_call_result(pid, call)
      ms = System.monotonic_time(:millisecond) - t0
      send(parent, {ref, :done, ms, result})
      send(logger, {log_ref, ms, result})
    end)

    receive do
      {^ref, :done, _ms, result} ->
        normalize_rpc_result(node_id, result)
    after
      timeout ->
        []
    end
  end

  defp rpc_read(nodes, call) when is_list(nodes) do
    me = self()
    ref = make_ref()

    Enum.map(nodes, fn node ->
      spawn_link(fn ->
        send(me, {ref, rpc_read_node(node, call)})
      end)
    end)
    |> Enum.map(fn _pid ->
      receive do
        {^ref, ret} -> ret
      end
    end)
  end

  defp rpc_read_node(%Node{node_id: node_id}, call) do
    address = Wallet.address!(node_id)

    case Map.get(ready_connections(), address) do
      nil ->
        []

      pid ->
        rpc_with_cutoff(node_id, pid, call, @rpc_read_timeout)
    end
  end

  defp rpc_call_result(pid, call) do
    try do
      GenServer.call(pid, {:rpc, call}, @rpc_peer_call_timeout)
    rescue
      error -> {:rpc_error, error}
    catch
      :exit, reason -> {:rpc_exit, reason}
    end
  end

  defp normalize_rpc_result(node_id, result) do
    case result do
      {:rpc_error, error} ->
        Logger.warning(
          "Failed to get a result from #{Wallet.printable(node_id)} #{inspect(error)}"
        )

        []

      {:rpc_exit, {:normal, _}} ->
        []

      {:rpc_exit, reason} ->
        Logger.warning(
          "Failed to get a result from #{Wallet.printable(node_id)} #{inspect(reason)}"
        )

        []

      other ->
        other
    end
  end

  @doc false
  def rpc_with_cutoff_test(node_id, pid, call), do: rpc_with_cutoff(node_id, pid, call)

  defp log_rpc_after_cutoff(node_id, log_ref, timeout) do
    printable = Wallet.printable(node_id)

    receive do
      {^log_ref, ms, _result} when ms > timeout ->
        Logger.info(
          "Slow RPC from #{printable} completed in #{ms}ms (lookup cutoff #{timeout}ms)"
        )

      {^log_ref, _ms, _result} ->
        :ok
    after
      120_000 ->
        Logger.info("RPC from #{printable} did not complete (lookup cutoff #{timeout}ms)")
    end
  end

  def rpcast(%Node{} = node, call) do
    GenServer.cast(ensure_node_connection(node), {:rpc, call})
  end

  defp queue_redistribute(node) do
    Debouncer.apply(
      {:redistribute, node.node_id},
      fn -> redistribute(node) end,
      :timer.minutes(2)
    )
  end

  @max_key 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF

  def node_range(node, network \\ ring_nodes()) do
    online = ready_connections()

    node =
      case node do
        %Node{} -> node
        key -> Enum.find(network, fn n -> KademliaRing.key(n) == KademliaRing.key(key) end)
      end

    previ =
      case filter_online(KademliaRing.prev(network, node), online) do
        [prev | _] -> KademliaRing.integer(prev)
        [] -> KademliaRing.integer(node)
      end

    nodei = KademliaRing.integer(node)

    nexti =
      case filter_online(KademliaRing.next(network, node), online) do
        [next | _] -> KademliaRing.integer(next)
        [] -> KademliaRing.integer(node)
      end

    range_start = rem(div(previ + nodei, 2), @max_key)
    range_end = rem(div(nexti + nodei, 2), @max_key)
    {range_start, range_end}
  end

  defp redistribute(node) do
    network = ring_nodes()

    if KademliaRing.member?(network, node.node_id) do
      {range_start, range_end} = node_range(node, network)
      objs = KademliaSql.objects(range_start, range_end)
      redist = Enum.shuffle(objs) |> Enum.take(100)

      Logger.info(
        "Redistributing #{length(redist)} of #{length(objs)} objects to #{inspect(Wallet.printable(node.node_id))}"
      )

      ready = ready_connections()

      if Map.has_key?(ready, node.address) do
        Enum.each(redist, fn {key, value} ->
          rpc(node, [PeerHandlerV2.store(), key, value])
        end)
      end
    end
  end

  def redistribute_stale(network, %Node{} = node) do
    {range_start, range_end} = node_range(node, network)

    objs = KademliaSql.objects(range_start, range_end)

    redist =
      objs
      |> Enum.shuffle()
      |> Enum.take(100)

    Logger.info(
      "Redistributing #{length(redist)} of #{length(objs)} stale objects from #{inspect(Wallet.printable(node.node_id))}"
    )

    for {key, value} <- redist do
      repair_replicas(key, value)
    end
  end

  defp load_ring() do
    nodes =
      KademliaSql.list_on_chain_nodes()
      |> Enum.map(fn {node, _meta} -> node end)

    self_node = Node.new(Diode.wallet())

    if Enum.any?(nodes, fn n -> KademliaRing.is_self(n) end) do
      nodes
    else
      [self_node | nodes]
    end
  end

  defp write_ets_ring(ring) do
    :ets.insert(@ets_table, {:ring, ring})

    for node <- ring do
      update_ets_meta(node.node_id)
    end
  end

  defp update_ets_meta(node_id) do
    address = Wallet.address!(node_id)
    meta = KademliaSql.get_node(address) || %{}
    ready = ready_connections()

    meta =
      Map.merge(meta, %{
        connected: Map.has_key?(ready, address) or KademliaRing.is_self(node_id)
      })

    :ets.insert(@ets_table, {address, meta})
  end

  @doc false
  def discover_registry_objects(ring \\ nil) do
    ring = ring || ring_nodes()

    if map_size(ready_connections()) == 0 do
      0
    else
      now = System.os_time(:second)

      found =
        ring
        |> registry_nodes_missing_object_list()
        |> Enum.shuffle()
        |> Enum.take(@discover_batch)
        |> Enum.reduce(0, fn node, acc ->
          if discover_throttled?(node.address, now) do
            acc
          else
            :ets.insert(@discover_throttle_table, {node.address, now})

            case discover_one_node(node) do
              :found -> acc + 1
              _ -> acc
            end
          end
        end)

      KademliaSql.refresh_known_good_all()
      found
    end
  end

  @doc false
  def registry_nodes_missing_object(ring \\ nil) do
    (ring || ring_nodes())
    |> registry_nodes_missing_object_list()
    |> length()
  end

  defp registry_nodes_missing_object_list(ring) do
    ring
    |> Enum.reject(&KademliaRing.is_self/1)
    |> Enum.filter(fn %Node{ring_key: ring_key} ->
      KademliaSql.object(ring_key) == nil
    end)
  end

  defp discover_throttled?(address, now) do
    case :ets.lookup(@discover_throttle_table, address) do
      [{^address, last}] when now - last < @discover_throttle_seconds -> true
      _ -> false
    end
  end

  defp discover_one_node(%Node{address: address, ring_key: ring_key}) do
    if KademliaSql.object(ring_key) != nil do
      :already
    else
      case find_value(address) do
        nil ->
          :miss

        value when is_binary(value) ->
          KademliaSql.maybe_update_object(ring_key, value)
          KademliaSql.refresh_known_good(address)
          :found
      end
    end
  end

  defp contact_registry_nodes(ring) do
    ready = ready_connections()
    now = System.os_time(:second)

    for node <- ring, not KademliaRing.is_self(node) do
      address = node.address
      meta = KademliaSql.get_node(address)

      if meta != nil and KademliaSql.object(node.ring_key) != nil do
        if Map.has_key?(ready, address) do
          KademliaSql.upsert_node_from_connection(node.node_id, %{
            known_good: true,
            last_connected: now
          })

          update_ets_meta(node.node_id)
        else
          if should_retry?(meta, now) do
            ensure_node_connection(node)
          end
        end
      end
    end
  end

  defp contact_seed_nodes() do
    list = Diode.default_peer_list()
    Logger.info("Contacting #{length(list)} seeds")

    for peer_server <- list do
      %URI{userinfo: node_id, host: address, port: port} = URI.parse(peer_server)

      id =
        case node_id do
          nil -> Wallet.new()
          str -> Wallet.from_address(Base16.decode(str))
        end

      Network.Server.ensure_node_connection(PeerHandlerV2, id, address, port)
    end
  end

  defp should_retry?(nil, _now), do: true

  defp should_retry?(meta, now) do
    case meta.next_retry do
      nil -> true
      t when t <= now -> true
      _ -> false
    end
  end

  def next_retry_at(nil), do: System.os_time(:second)

  def next_retry_at(meta) do
    failures = Map.get(meta, :failures, 0) || 0
    last = Map.get(meta, :last_error) || System.os_time(:second)
    last + fib_delay(failures)
  end

  defp fib_delay(0), do: 0

  defp fib_delay(failures) do
    n = min(failures, @fib_max_index)
    min(fib(n), @max_retry_seconds)
  end

  defp fib(n) when n <= 0, do: 0
  defp fib(1), do: 1
  defp fib(2), do: 1

  defp fib(n) do
    {_a, b} = Enum.reduce(2..n, {1, 1}, fn _, {a, b} -> {b, a + b} end)
    b
  end

  defp ensure_node_connection(%Node{node_id: node_id} = node) do
    if KademliaRing.is_self(node) do
      Network.Server.ensure_node_connection(
        PeerHandlerV2,
        node_id,
        "localhost",
        Diode.peer2_port()
      )
    else
      case KademliaSql.object(node.ring_key) do
        nil ->
          :error

        encoded ->
          server = Object.decode!(encoded)
          host = Server.host(server)
          port = Server.peer_port(server)
          Network.Server.ensure_node_connection(PeerHandlerV2, node_id, host, port)
      end
    end
  end

  defp do_find_value_quorum(key, rpc_fun \\ &rpc_read/2, online \\ nil) do
    local_value = KademliaSql.object(key)
    value_responses = if local_value, do: [local_value], else: []

    {replica_remote, _} = replica_targets(key, online)

    results =
      if replica_remote == [] do
        []
      else
        rpc_fun.(replica_remote, [PeerHandlerV2.find_value(), key])
      end

    value_responses =
      Enum.zip(replica_remote, results)
      |> Enum.reduce(value_responses, fn {_node, result}, responses ->
        absorb_peer_hints(peer_hint_list(result))
        append_value_response(result, responses)
      end)

    if read_quorum_met?(length(value_responses)) do
      case quorum_select_value(value_responses) do
        nil -> :miss
        best -> {:value, best}
      end
    else
      :miss
    end
  end

  defp append_value_response({:value, value}, responses), do: [value | responses]
  defp append_value_response(_result, responses), do: responses

  defp choose_newer_value(value, nil), do: value

  defp choose_newer_value(value, best) do
    if Object.block_number(Object.decode!(best)) >
         Object.block_number(Object.decode!(value)) do
      best
    else
      value
    end
  end

  defp peer_hint_list({:value, _}), do: []
  defp peer_hint_list(list) when is_list(list), do: list
  defp peer_hint_list(_), do: []

  @doc false
  def replica_targets(key, online \\ nil) do
    key = hash(key)
    ready = online || ready_connections()

    nearest =
      ring_nodes()
      |> KademliaRing.nearest_n(key, @n)

    self_in_set? = Enum.any?(nearest, &KademliaRing.is_self/1)

    remote =
      nearest
      |> Enum.reject(&KademliaRing.is_self/1)
      |> filter_online(ready)

    {remote, self_in_set?}
  end

  defp replica_candidates(key, online) do
    key = hash(key)
    ready = online || ready_connections()

    ring_nodes()
    |> KademliaRing.nearest(key)
    |> Enum.reject(&KademliaRing.is_self/1)
    |> filter_online(ready)
  end

  defp sort_connected_first(nodes, online) do
    Enum.sort_by(nodes, fn %Node{address: address} ->
      if Map.has_key?(online, address), do: 0, else: 1
    end)
  end

  @doc false
  def sort_connected_first_test(nodes, online), do: sort_connected_first(nodes, online)

  defp quorum_store_remote(hkey, value, rpc_fun, online \\ nil) do
    all_candidates = replica_candidates(hkey, online)

    {initial, _} = replica_targets(hkey, online)
    initial = if initial == [], do: Enum.take(all_candidates, @n), else: initial

    case do_quorum_store(hkey, value, rpc_fun, initial, all_candidates, MapSet.new(), online) do
      :ok ->
        :ok

      {:error, :quorum_not_met, stats} ->
        Logger.warning("store quorum not met for #{Base16.encode(hkey)}: #{inspect(stats)}")

        {:error, :quorum_not_met, stats}
    end
  end

  defp do_quorum_store(hkey, value, rpc_fun, batch, all_candidates, tried, online) do
    ready = online || ready_connections()

    ready_batch =
      Enum.filter(batch, fn %Node{address: address} ->
        Map.has_key?(ready, address)
      end)

    results =
      if ready_batch == [] do
        []
      else
        rpc_fun.(ready_batch, [PeerHandlerV2.store(), hkey, value])
      end

    %{acked: acked} = classify_store_results(ready_batch, results)

    tried =
      Enum.reduce(ready_batch, tried, fn node, acc ->
        MapSet.put(acc, KademliaRing.key(node))
      end)

    total = 1 + length(acked)

    if total >= @w do
      :ok
    else
      remaining =
        Enum.reject(all_candidates, fn node ->
          MapSet.member?(tried, KademliaRing.key(node))
        end)

      fallback = Enum.take(remaining, @n)

      if fallback == [] do
        {:error, :quorum_not_met, %{acked: total, tried: MapSet.size(tried)}}
      else
        do_quorum_store(hkey, value, rpc_fun, fallback, all_candidates, tried, online)
      end
    end
  end

  @doc false
  def store_ack?(result), do: result == ["ok"] or result == "ok"

  defp classify_store_results(nodes, results) do
    Enum.zip(nodes, results)
    |> Enum.reduce(%{acked: [], failed: []}, fn {node, result}, acc ->
      if store_ack?(result) do
        %{acc | acked: [node | acc.acked]}
      else
        %{acc | failed: [node | acc.failed]}
      end
    end)
  end

  @doc false
  def write_quorum_met?(remote_acks) when is_integer(remote_acks) do
    1 + remote_acks >= @w
  end

  @doc false
  def read_quorum_met?(response_count) when is_integer(response_count) do
    response_count >= @r
  end

  @doc false
  def quorum_select_value([]), do: nil

  def quorum_select_value([value]), do: value

  def quorum_select_value(values) do
    Enum.reduce(values, fn value, acc -> choose_newer_value(value, acc) end)
  end

  defp merge_local_find_value(key, remote_value) do
    case KademliaSql.object(key) do
      nil ->
        remote_value

      local_ret ->
        if Object.block_number(Object.decode!(local_ret)) <
             Object.block_number(Object.decode!(remote_value)) do
          KademliaSql.put_object(key, remote_value)
          remote_value
        else
          local_ret
        end
    end
  end

  defp repair_replicas(key, value) when is_binary(value) do
    {remote, _} = replica_targets(key)

    if remote != [] do
      results = rpc(remote, [PeerHandlerV2.store(), key, value])
      repaired = classify_store_results(remote, results).acked

      if repaired != [] do
        Logger.debug(
          "repair_replicas #{Base16.encode(key)}: pushed to #{length(repaired)} peer(s)"
        )
      end
    end

    :ok
  end

  @doc false
  def store_with_rpc(key, value, rpc_fun, online \\ nil) when is_function(rpc_fun, 2) do
    hkey = hash(key)
    KademliaSql.maybe_update_object(hkey, value)
    quorum_store_remote(hkey, value, rpc_fun, online)
  end

  @doc false
  def find_value_with_rpc(key, rpc_fun, online \\ nil) when is_function(rpc_fun, 2) do
    key = hash(key)

    case do_find_value_quorum(key, rpc_fun, online) do
      {:value, value} ->
        value = merge_local_find_value(key, value)
        repair_replicas_with_rpc(key, value, rpc_fun)
        value

      :miss ->
        case KademliaSql.object(key) do
          nil -> nil
          local_ret -> local_ret
        end
    end
  end

  defp repair_replicas_with_rpc(key, value, rpc_fun) do
    {remote, _} = replica_targets(key)

    if remote != [] do
      rpc_fun.(remote, [PeerHandlerV2.store(), key, value])
    end

    :ok
  end

  @doc false
  def repair_replicas_with_rpc_test(key, value, rpc_fun, ready)
      when is_function(rpc_fun, 2) and is_map(ready) do
    hkey = hash(key)

    connected =
      ring_nodes()
      |> KademliaRing.nearest_n(hkey, @n)
      |> Enum.reject(&KademliaRing.is_self/1)
      |> filter_online(ready)

    if connected != [] do
      rpc_fun.(connected, [PeerHandlerV2.store(), hkey, value])
    end

    :ok
  end

  @doc false
  def absorb_peer_hints(items) when is_list(items) do
    Enum.each(items, fn
      %{object: object} when not is_nil(object) ->
        KademliaSql.maybe_update_object(nil, object)

      _ ->
        :ok
    end)
  end

  def nearest_n(key) do
    ring_nodes()
    |> filter_online()
    |> KademliaRing.nearest_n(key, @n)
  end

  defp replica_hint_nodes(key) do
    ring_nodes()
    |> KademliaRing.nearest_n(key, @n)
    |> Enum.reject(&KademliaRing.is_self/1)
  end

  def filter_online(list, online \\ ready_connections()) do
    Enum.filter(list, fn %Node{node_id: wallet} = node ->
      KademliaRing.is_self(node) or Map.has_key?(online, Wallet.address!(wallet))
    end)
  end

  defp node_object(%Node{} = node) do
    case KademliaSql.object(node.ring_key) do
      nil -> nil
      binary -> Object.decode!(binary)
    end
  end

  @cache_timeout 20_000

  @doc false
  def get_cached_test(fun, cache_key, arg), do: get_cached(fun, cache_key, arg)

  defp get_cached(fun, cache_key, arg) do
    ets_key = {fun, cache_key}

    case ETSLru.get(__MODULE__, ets_key) do
      nil ->
        ETSLru.fetch(__MODULE__, ets_key, fn -> fun.(arg) end)

      other ->
        Debouncer.immediate(
          ets_key,
          fn -> ETSLru.put(__MODULE__, ets_key, fun.(arg)) end,
          @cache_timeout
        )

        other
    end
  end

  def hash(binary) do
    Diode.hash(binary)
  end
end
