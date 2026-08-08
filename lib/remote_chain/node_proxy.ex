# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule RemoteChain.NodeProxy do
  @moduledoc """
  Manage websocket connections to the given chain rpc node
  """
  use GenServer, restart: :permanent
  alias DiodeClient.{Base16, Rlp}
  alias RemoteChain.RPCCache
  alias RemoteChain.NodeProxy
  require Logger
  @default_timeout 25_000
  @rate_limit_reconnect_ms 15_000
  @security_level 1

  # A WSConn that has gone this many expected block intervals without a new
  # block is forcibly evicted, even though the socket itself is still alive.
  # Two consecutive ping cycles (each 2 * expected_block_intervall seconds) is
  # the upper bound: WSConn's own :ping handler closes a connection at 10 *
  # expected_block_intervall, so we keep it in the pool for one cycle longer
  # in case it recovers, then evict + ask ChainList to re-test the URL.
  @stale_eviction_intervals 20

  defstruct [
    :chain,
    connections: %{},
    req: 100,
    requests: %{},
    lastblocks: %{},
    lastblock: 0,
    subscriptions: %{},
    log: nil,
    fallback: nil,
    fallback_url: nil
  ]

  def start_link(chain) do
    GenServer.start_link(__MODULE__, %NodeProxy{chain: chain, connections: %{}},
      name: name(chain)
    )
  end

  @impl true
  def init(%NodeProxy{} = state) do
    File.mkdir_p!("logs")
    {:ok, log} = RotatingFile.start_link(file: "logs/#{state.chain}.log", name: nil)
    state = %NodeProxy{state | log: log}
    {:ok, ensure_connections(state)}
  end

  def rpc(chain, method, params) do
    GenServerDbg.call(name(chain), {:rpc, method, params}, @default_timeout)
  end

  @doc """
  Returns in-flight upstream RPC info for `caller_pid`, if any.

  Used by slow-path diagnostics (e.g. EdgeV2 `Profiler.warn_if_stuck`) to
  report which provider a blocked caller is waiting on.
  """
  def pending_for_caller(chain, caller_pid) do
    try do
      GenServer.call(name(chain), {:pending_for, caller_pid}, 1_000)
    catch
      :exit, _ -> nil
    end
  end

  @doc false
  def pending_request_info(%NodeProxy{requests: requests}, caller_pid) do
    now = System.os_time(:millisecond)

    Enum.find_value(requests, fn {_id, req} ->
      if req.from == caller_pid do
        %{method: req.method, ws_url: req.ws_url, age_ms: now - req.start_ms}
      end
    end)
  end

  def subscribe_block(chain, opts \\ []) do
    GenServer.cast(name(chain), {:subscribe_block, self(), opts})
  end

  def unsubscribe_block(chain) do
    GenServer.cast(name(chain), {:unsubscribe_block, self()})
  end

  @doc """
  Resets lastblock state. Used when the chain is restarted (e.g. anvil in tests)
  so the next block from the chain will be forwarded to RPCCache.
  """
  def reset_lastblock(chain) do
    GenServer.cast(name(chain), :reset_lastblock)
  end

  @impl true
  def handle_call({:rpc, method, params}, from, state) do
    state = ensure_connections(state)

    case pick_connection(state) do
      {:ok, conn} ->
        id = state.req + 1
        state = send_request(state, conn, id, method, params, from)
        {:noreply, %{state | req: id}}

      {:error, :no_ready_connection} ->
        {:reply, {:error, :disconnect}, state}
    end
  end

  def handle_call({:pending_for, caller_pid}, _from, state) do
    {:reply, pending_request_info(state, caller_pid), state}
  end

  # Prefer WSConns that finished `handle_connect/2` (see `WSConn.ready?/1`).
  @doc false
  def pick_connection(%NodeProxy{connections: connections, fallback: fallback}) do
    ready =
      connections
      |> Map.values()
      |> Enum.filter(&RemoteChain.WSConn.ready?/1)

    cond do
      ready != [] ->
        {:ok, Enum.random(ready)}

      fallback != nil and RemoteChain.WSConn.ready?(fallback) ->
        {:ok, fallback}

      true ->
        handshaking =
          connections
          |> Map.values()
          |> Enum.filter(&young_handshake?/1)

        case handshaking do
          [] -> {:error, :no_ready_connection}
          pids -> {:ok, Enum.random(pids)}
        end
    end
  end

  defp young_handshake?(pid) do
    not RemoteChain.WSConn.ready?(pid) and not RemoteChain.WSConn.handshake_stale?(pid)
  end

  @impl true
  def handle_cast(:ensure_connections, state) do
    {:noreply, ensure_connections(state)}
  end

  def handle_cast(
        {:subscribe_block, pid, opts},
        state = %NodeProxy{subscriptions: subs, lastblock: lastblock}
      ) do
    if opts[:trigger] == true and lastblock > 0 do
      send(pid, {{__MODULE__, state.chain}, :block_number, lastblock})
    end

    if Map.has_key?(subs, pid) do
      {:noreply, state}
    else
      ref = Process.monitor(pid)
      {:noreply, %{state | subscriptions: Map.put(subs, pid, ref)}}
    end
  end

  def handle_cast({:unsubscribe_block, pid}, state = %NodeProxy{subscriptions: subs}) do
    Process.demonitor(subs[pid])
    {:noreply, %{state | subscriptions: Map.delete(subs, pid)}}
  end

  def handle_cast(:reset_lastblock, state = %NodeProxy{}) do
    {:noreply, %{state | lastblock: 0, lastblocks: %{}}}
  end

  @impl true
  def handle_info(
        {:new_block, ws_url, block_number},
        state = %NodeProxy{
          chain: chain,
          lastblocks: lastblocks,
          subscriptions: subs,
          lastblock: lastblock,
          fallback: fallback,
          fallback_url: fallback_url
        }
      ) do
    now = DateTime.utc_now()
    lastblocks = Map.put(lastblocks, ws_url, {block_number, now})

    # A provider that has been silent for more than the staleness cutoff
    # contributes zero votes to the quorum. Otherwise a single frozen
    # fallback would block every block advance (the us1/Oasis incident).
    live_voter_count =
      Enum.count(lastblocks, fn {_url, {block, lastblock_at}} ->
        block >= block_number and not RemoteChain.WSConn.stale_at?(lastblock_at, chain)
      end)

    # Prefer the cached `lastblocks` entry so the consensus path never makes
    # a `:sys.get_state` call to the fallback pid. Fall back to the WSConn's
    # own `lastblock_at` only when the fallback has never reported a block.
    fallback_live? =
      fallback != nil and
        case Map.get(lastblocks, fallback_url) do
          {_block, lastblock_at} -> not RemoteChain.WSConn.stale_at?(lastblock_at, chain)
          nil -> not RemoteChain.WSConn.stale?(fallback, chain)
        end

    security_level = if fallback_live?, do: @security_level + 1, else: @security_level

    block_number =
      if live_voter_count >= security_level do
        max(block_number, lastblock)
      else
        lastblock
      end

    if block_number > lastblock do
      pid = :global.whereis_name({RPCCache, chain})

      if pid != :undefined do
        send(pid, {{__MODULE__, chain}, :block_number, block_number})
      end

      for {pid, _ref} <- subs do
        send(pid, {{__MODULE__, chain}, :block_number, block_number})
      end
    end

    {:noreply, %{state | lastblocks: lastblocks, lastblock: block_number}}
  end

  def handle_info(
        {:DOWN, _ref, :process, down_pid, reason},
        state = %{subscriptions: subs}
      ) do
    if Map.has_key?(subs, down_pid) do
      subs = Map.delete(subs, down_pid)
      {:noreply, %{state | subscriptions: subs}}
    else
      if reason != :normal do
        Logger.warning(
          "WSConn #{inspect(down_pid)} of #{inspect(state.chain)} disconnected for #{inspect(reason)}"
        )
      end

      delay_ms = if rate_limited_disconnect?(reason), do: @rate_limit_reconnect_ms, else: 0

      {:noreply, state |> remove_connection(down_pid) |> schedule_ensure_connections(delay_ms)}
    end
  end

  def handle_info(
        {:response, _ws_url, %{"id" => id} = response},
        state = %NodeProxy{fallback: fallback}
      ) do
    case Map.pop(state.requests, id) do
      {nil, _} ->
        Logger.warning("No request found for response: #{inspect(response)}")
        {:noreply, state}

      {%{
         from: from,
         start_ms: start_ms,
         method: method,
         params: params,
         conn: conn,
         ws_url: ws_url,
         request: request
       }, requests} ->
        time_ms = System.os_time(:millisecond) - start_ms

        if time_ms > 400 do
          params =
            if method == "dio_edgev2" do
              Base16.decode(hd(params)) |> Rlp.decode!()
            else
              params
            end

          Logger.debug("RPC #{method} #{inspect(params)} via #{ws_url} took #{time_ms}ms")
        end

        if fallback != nil and RemoteChain.WSConn.ready?(fallback) and conn != fallback and
             is_fallback_candidate(method, response) do
          Logger.info("RPC #{method} #{inspect(params)} retrying with fallback")
          state = send_request(%{state | requests: requests}, fallback, id, method, params, from)
          {:noreply, state}
        else
          log_rpc_call(state.log, request, response)
          GenServer.reply(from, response)
          {:noreply, %{state | requests: requests}}
        end
    end
  end

  def is_fallback_candidate(method, response) do
    result = response["result"]
    error_message = get_in(response, ["error", "message"]) || ""

    cond do
      # -32603 is the Moonbeam code for "State already discarded"
      get_in(response, ["error", "code"]) == -32603 ->
        true

      # Oasis chain error message for block not found
      String.contains?(error_message, "roothash: block not found") ->
        true

      method == "eth_getStorageAt" ->
        result == "0x0000000000000000000000000000000000000000000000000000000000000000"

      method == "eth_getCode" ->
        result == "0x"

      true ->
        Map.has_key?(response, "result") and result == nil
    end
  end

  @doc false
  def rpc_log_status(response) do
    cond do
      Map.has_key?(response, "error") ->
        ":error"

      # Flat error envelope (no nested `"error"` key)
      Map.has_key?(response, "code") and Map.has_key?(response, "message") ->
        ":error"

      true ->
        ":ok"
    end
  end

  defp log_rpc_call(log, request, response) do
    ts = DateTime.utc_now() |> DateTime.to_iso8601()
    RotatingFile.write(log, "#{ts} #{request} #{rpc_log_status(response)}\n")
  end

  defp send_request(state, conn, id, method, params, from) do
    request =
      %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => method,
        "params" => params
      }
      |> Poison.encode!()

    ret = RemoteChain.WSConn.send_request(conn, request)

    if :ok == ret do
      requests =
        Map.put(state.requests, id, %{
          from: from,
          method: method,
          params: params,
          start_ms: System.os_time(:millisecond),
          conn: conn,
          ws_url: conn_url(state, conn),
          request: request
        })

      %{state | requests: requests}
    else
      Logger.warning(
        "Failed to send request to #{inspect(conn)}: #{inspect(request)}: #{inspect(ret)}"
      )

      GenServer.reply(from, {:error, :disconnect})
      handle_failed_send(state, conn)
    end
  end

  # See moduledoc in `node_proxy_test.exs` for the `:not_connected` handshake cases.
  @doc false
  def handle_failed_send(state, conn) do
    if not Process.alive?(conn) or RemoteChain.WSConn.ready?(conn) or
         RemoteChain.WSConn.handshake_stale?(conn) do
      state |> close_and_remove(conn) |> schedule_ensure_connections()
    else
      state
    end
  end

  defp remove_connection(
         state = %NodeProxy{
           connections: connections,
           requests: requests,
           fallback: fallback,
           fallback_url: fallback_url
         },
         down_pid
       ) do
    requests =
      Enum.reject(requests, fn {_, %{conn: conn, from: from}} ->
        if conn == down_pid do
          GenServer.reply(from, {:error, :disconnect})
          true
        else
          false
        end
      end)
      |> Map.new()

    new_connections = Enum.filter(connections, fn {_, pid} -> pid != down_pid end) |> Map.new()

    {new_fallback, new_fallback_url} =
      if fallback == down_pid, do: {nil, nil}, else: {fallback, fallback_url}

    %{
      state
      | connections: new_connections,
        requests: requests,
        fallback: new_fallback,
        fallback_url: new_fallback_url
    }
  end

  @doc false
  def prune_stale_connections(
        state = %NodeProxy{
          chain: chain,
          connections: connections,
          fallback: fallback,
          fallback_url: fallback_url
        }
      ) do
    pool =
      if fallback_url && fallback,
        do: Map.put(connections, fallback_url, fallback),
        else: connections

    state =
      Enum.reduce(pool, state, fn {url, pid}, state ->
        cond do
          RemoteChain.WSConn.handshake_stale?(pid) ->
            Logger.warning(
              "Evicting handshake-stale WSConn #{inspect(pid)} for #{inspect(state.chain)} [#{url}]"
            )

            close_and_remove(state, pid)

          data_stale?(state, chain, url, pid) ->
            Logger.warning(
              "Evicting data-stale WSConn #{inspect(pid)} for #{inspect(state.chain)} [#{url}] " <>
                "(no new blocks for >#{@stale_eviction_intervals} block intervals)"
            )

            close_and_remove(state, pid)

          true ->
            state
        end
      end)

    # If we removed the fallback, the pool is now operating without one
    # even though the chain config still lists fallback URLs. Schedule a
    # refill so the next fallback URL (or none, if all are stale) takes
    # its place.
    removed_fallback? = fallback != nil and state.fallback == nil

    if removed_fallback? do
      schedule_ensure_connections(state, 0)
    else
      state
    end
  end

  # Whether `url` is associated with a WSConn that has been silent for
  # longer than `@stale_eviction_intervals` block intervals. Uses the
  # cached `lastblocks` entry when present (more accurate than
  # WSConn's `lastblock_at`, which is the connection's last frame), and
  # falls back to the WSConn's own `lastblock_at` via `lastblock_at/1`
  # so a never-blocked connection is still evicted after the cutoff.
  defp data_stale?(%NodeProxy{lastblocks: lastblocks}, chain, url, pid) do
    lastblock_at =
      case Map.get(lastblocks, url) do
        {_block, ts} -> ts
        nil -> RemoteChain.WSConn.lastblock_at(pid)
      end

    RemoteChain.WSConn.stale_at?(lastblock_at, chain, @stale_eviction_intervals)
  end

  defp close_and_remove(state, pid) do
    if Process.alive?(pid) do
      if RemoteChain.WSConn.wsconn_process?(pid) do
        RemoteChain.WSConn.close(pid)
      else
        Process.exit(pid, :kill)
      end
    end

    remove_connection(state, pid)
  end

  defp conn_url(
         %NodeProxy{connections: connections, fallback: fallback, fallback_url: fallback_url},
         conn
       ) do
    Enum.find_value(connections, fn {url, pid} -> if pid == conn, do: url end) ||
      if fallback == conn, do: fallback_url
  end

  defp schedule_ensure_connections(state, delay_ms \\ 0) do
    pid = self()
    key = {__MODULE__, pid, :ensure_connections}

    fun = fn ->
      GenServer.cast(pid, :ensure_connections)
    end

    if delay_ms > 0 do
      # `apply` keeps the first scheduled fire time so repeated 429s don't reset
      # the cooldown (unlike `delay`, which would keep pushing it out forever).
      Debouncer.apply(key, fun, delay_ms)
    else
      Debouncer.immediate(key, fun)
    end

    state
  end

  @doc false
  def rate_limited_disconnect?(reason) do
    message =
      case reason do
        bin when is_binary(bin) ->
          bin

        %WebSockex.RequestError{code: code, message: msg} ->
          "#{code} #{msg}"

        {:error, %WebSockex.RequestError{code: code, message: msg}} ->
          "#{code} #{msg}"

        exc when is_exception(exc) ->
          Exception.message(exc)

        other ->
          inspect(other)
      end
      |> String.downcase()

    limited? =
      String.contains?(message, "429") or String.contains?(message, "too many requests")

    if limited? do
      :persistent_term.put(
        {__MODULE__, :rate_limited_until},
        System.monotonic_time(:millisecond) + @rate_limit_reconnect_ms
      )
    end

    limited?
  end

  defp ensure_connections(state = %NodeProxy{chain: chain}) do
    state = prune_stale_connections(state)
    %NodeProxy{connections: connections, fallback: fallback} = state

    # Apply `live_ws_endpoints/1` to BOTH the primary list and the configured
    # fallback URLs. Without filtering fallback URLs, a permanently stale
    # WS-only fallback (e.g. the simplystaking.xyz endpoint on us1) would be
    # re-attached after every eviction and silently freeze the published
    # block number forever.
    fallback_candidates = RemoteChain.ws_fallback_endpoints(chain)
    urls = MapSet.new(RemoteChain.ChainList.live_ws_endpoints(chain, fallback_candidates))
    existing = MapSet.new(Map.keys(connections))
    new_urls = MapSet.difference(urls, existing) |> Enum.to_list() |> Enum.shuffle()
    fallback_url = List.first(Enum.shuffle(fallback_candidates) ++ new_urls)

    cond do
      map_size(connections) < @security_level ->
        case pick_url(urls, existing, new_urls) do
          nil ->
            state

          new_url ->
            pid = RemoteChain.WSConn.start(self(), chain, new_url)
            Process.monitor(pid)
            state = %{state | connections: Map.put(connections, new_url, pid)}
            ensure_connections(state)
        end

      fallback == nil and fallback_url != nil ->
        pid = RemoteChain.WSConn.start(self(), chain, fallback_url)
        Process.monitor(pid)
        state = %{state | fallback: pid, fallback_url: fallback_url}
        ensure_connections(state)

      true ->
        state
    end
  end

  # Prefer never-used URLs, then any configured URL not in the live pool
  # (allows reconnecting the same endpoint after eviction).
  defp pick_url(urls, existing, new_urls) do
    cond do
      new_urls != [] ->
        Enum.random(new_urls)

      true ->
        urls
        |> MapSet.difference(existing)
        |> Enum.to_list()
        |> case do
          [] -> nil
          available -> Enum.random(available)
        end
    end
  end

  def name(chain) do
    impl = RemoteChain.chainimpl(chain)
    {:global, {__MODULE__, impl}}
  end
end
