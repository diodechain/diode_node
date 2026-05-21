# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule KademliaLight do
  @moduledoc """
  K* light-node DHT: geometric ring over on-chain NodeRegistry members,
  node metadata in SQLite, live connection state in ETS.
  """
  use GenServer
  alias KademliaLight.Node
  alias Network.PeerHandlerV2
  alias DiodeClient.{Base16, ETSLru, Object, Object.Server, Wallet}
  alias Model.KademliaSql
  require Logger

  @k 3
  @k_search KademliaRing.k()
  @alpha 3
  @max_oid 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF + 1
  @ets_table :kademlia_network
  @redistribute_interval :timer.minutes(2)
  @contact_interval :timer.minutes(1)
  @discover_batch 40
  @discover_throttle_seconds 3600
  @discover_throttle_table :kademlia_discover_throttle
  @max_retry_seconds 6 * 3600
  @fib_max_index 28

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
    nodes =
      find_nodes(key)
      |> Enum.take(@k)

    rpc(nodes, [PeerHandlerV2.store(), hash(key), value])
  end

  def find_value(key) do
    key = hash(key)

    nodes = get_cached(&do_find_value/1, {:find_value, key}, key)

    case nodes do
      {:value, value, visited} ->
        result = KademliaRing.nearest_n(visited, key, @k_search)

        value =
          with local_ret when local_ret != nil <- KademliaSql.object(key),
               local_block <- Object.block_number(Object.decode!(local_ret)),
               value_block <- Object.block_number(Object.decode!(value)) do
            if local_block < value_block do
              KademliaSql.put_object(key, value)
              value
            else
              with true <- local_block > value_block,
                   nearest when nearest != nil <- Enum.at(result, 0) do
                rpcast(nearest, [PeerHandlerV2.store(), key, local_ret])
              end

              local_ret
            end
          else
            _ -> value
          end

        with second_nearest when second_nearest != nil <- Enum.at(result, 1) do
          rpcast(second_nearest, [PeerHandlerV2.store(), key, value])
        end

        value

      visited ->
        local_ret = KademliaSql.object(key)

        if local_ret != nil do
          for node <- Enum.take(visited, 2) do
            rpcast(node, [PeerHandlerV2.store(), key, local_ret])
          end
        end

        local_ret
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
    nearest_n(key) |> Enum.take(@k_search)
  end

  def find_node_lookup(key) do
    key = hash(key)
    get_cached(&nearest_n/1, {:find_node_lookup, key}, key)
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

    case KademliaSql.sync_registry_nodes() do
      :error -> KademliaSql.ensure_self_node_for_init()
      :ok -> :ok
    end

    ring = load_ring()
    write_ets_ring(ring)

    :timer.send_interval(@contact_interval, :contact_nodes)
    :timer.send_interval(@redistribute_interval, :scan_redistribution)

    {:ok, %__MODULE__{ring: ring, version: 3}, {:continue, :seed}}
  end

  @impl true
  def handle_continue(:seed, state) do
    handle_info(:contact_nodes, state)
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
    online = Network.Server.get_connections(PeerHandlerV2)

    for {address, _ring_key} <- KademliaSql.nodes_needing_redistribution() do
      if not Map.has_key?(online, address) do
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

  def rpc(%Node{node_id: node_id} = node, call) do
    pid = ensure_node_connection(node)

    try do
      GenServer.call(pid, {:rpc, call}, 2000)
    rescue
      error ->
        Logger.warning(
          "Failed to get a result from #{Wallet.printable(node_id)} #{inspect(error)}"
        )

        []
    catch
      :exit, {:timeout, _} ->
        Debouncer.immediate(
          {:timeout, node_id},
          fn ->
            Logger.info("Timeout while getting a result from #{Wallet.printable(node_id)}")
          end,
          60_000
        )

        []

      :exit, {:normal, _} ->
        Debouncer.immediate(
          {:down, node_id},
          fn ->
            Logger.info(
              "Connection down while getting a result from #{Wallet.printable(node_id)}"
            )
          end,
          60_000
        )

        []

      any, what ->
        Logger.warning(
          "Failed(2) to get a result from #{Wallet.printable(node_id)} #{inspect({any, what})}"
        )

        []
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
    online = Network.Server.get_connections(PeerHandlerV2)

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

      Enum.each(redist, fn {key, value} ->
        rpcast(node, [PeerHandlerV2.store(), key, value])
      end)
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
      find_nodes(key)
      |> Enum.take(@k)
      |> Enum.each(fn n -> rpcast(n, [PeerHandlerV2.store(), key, value]) end)
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
    online = Network.Server.get_connections(PeerHandlerV2)

    meta =
      Map.merge(meta, %{
        connected: Map.has_key?(online, address) or KademliaRing.is_self(node_id)
      })

    :ets.insert(@ets_table, {address, meta})
  end

  @doc false
  def discover_registry_objects(ring \\ nil) do
    ring = ring || ring_nodes()

    if map_size(Network.Server.get_connections(PeerHandlerV2)) == 0 do
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

        _ ->
          :miss
      end
    end
  end

  defp contact_registry_nodes(ring) do
    online = Network.Server.get_connections(PeerHandlerV2)
    now = System.os_time(:second)

    for node <- ring, not KademliaRing.is_self(node) do
      address = node.address
      meta = KademliaSql.get_node(address)

      if meta != nil and KademliaSql.object(node.ring_key) != nil do
        if Map.has_key?(online, address) do
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

  defp do_find_value(key) do
    candidates =
      ring_nodes()
      |> filter_online()
      |> KademliaRing.nearest(key)

    do_find_value_waves(key, candidates, %{}, nil, MapSet.new())
  end

  defp do_find_value_waves(key, candidates, visited, best, queried) do
    unqueried =
      Enum.reject(candidates, fn node ->
        MapSet.member?(queried, KademliaRing.key(node))
      end)

    cond do
      unqueried == [] ->
        finalize_find_value(key, visited, best)

      should_stop_value_search?(key, visited, unqueried, best) ->
        finalize_find_value(key, visited, best)

      true ->
        wave = Enum.take(unqueried, @alpha)
        new_queried = Enum.reduce(wave, queried, &MapSet.put(&2, KademliaRing.key(&1)))

        results = rpc(wave, [PeerHandlerV2.find_value(), key])

        {visited, best} =
          Enum.zip(wave, results)
          |> Enum.reduce({visited, best}, fn {node, result}, {vis, b} ->
            vis = Map.put(vis, KademliaRing.key(node), node)
            absorb_peer_hints(peer_hint_list(result))
            {vis, pick_best_value(result, b)}
          end)

        do_find_value_waves(key, candidates, visited, best, new_queried)
    end
  end

  defp should_stop_value_search?(key, visited, unqueried, best) do
    cond do
      best != nil and map_size(visited) > 0 ->
        true

      map_size(visited) >= @k_search and not closer_candidates_remain?(key, visited, unqueried) ->
        true

      true ->
        false
    end
  end

  defp closer_candidates_remain?(key, visited, unqueried) do
    if map_size(visited) < @k_search do
      unqueried != []
    else
      min_dist =
        visited
        |> Map.keys()
        |> Enum.map(fn node_key -> KademliaRing.distance(key, node_key) end)
        |> Enum.sort()
        |> Enum.at(@k_search - 1) || @max_oid

      Enum.any?(unqueried, fn node -> KademliaRing.distance(key, node) < min_dist end)
    end
  end

  defp finalize_find_value(key, visited, best) do
    visited =
      visited
      |> Map.values()
      |> KademliaRing.nearest(key)

    if best do
      {:value, best, visited}
    else
      visited
    end
  end

  defp pick_best_value({:value, value}, best), do: choose_newer_value(value, best)
  defp pick_best_value(_result, best), do: best

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
    |> KademliaRing.nearest_n(key, @k_search)
  end

  def filter_online(list, online \\ Network.Server.get_connections(PeerHandlerV2)) do
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
