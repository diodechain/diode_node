# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule RemoteChain.WSConn do
  @moduledoc """
  Manage websocket connections to the given chain rpc node
  """
  use WebSockex
  alias RemoteChain.WSConn
  require Logger

  defstruct [
    :owner,
    :chain,
    :ws_url,
    :conn,
    :lastblock_at,
    :subscription_id,
    :started_at,
    lastblock_number: 0
  ]

  @connection_timeout_ms 20_000

  def connection_timeout_ms(), do: @connection_timeout_ms
  def handshake_timeout_ms(), do: @connection_timeout_ms

  # A connection is considered stale (and excluded from the block-number
  # consensus) once its last observed block is older than this many expected
  # block intervals. Single source of truth for the staleness threshold used
  # by `stale?/2`, the `:ping` close handler, `NodeProxy`'s staleness-aware
  # consensus and eviction, and `ChainList.block_current?/2`.
  @stale_threshold_intervals 10

  @doc """
  The default staleness threshold expressed as a multiple of
  `chain.expected_block_intervall()`. Exposed so `ChainList.block_current?/2`
  can share the same threshold instead of baking the literal `10` into its
  own predicate.
  """
  def stale_threshold_intervals, do: @stale_threshold_intervals

  @doc """
  Whether `lastblock_at` is older than the staleness cutoff for `chain`.

  The default cutoff is `chain.expected_block_intervall() *
  stale_threshold_intervals()` seconds (currently 10 intervals). `intervals`
  overrides the multiplier — used by `NodeProxy` for its eviction pass (two
  ping cycles, `@stale_eviction_intervals`).

  Frozen chains (see `RemoteChain.frozen?/1`) never satisfy this predicate:
  the chain is not producing blocks, so `lastblock_at` stays at connect
  time and would otherwise trigger constant evictions of healthy
  connections. Provider health is still enforced by TCP/WS disconnects
  and the subscription handshake (`handle_info(:ping, ...)`).

  This is the single threshold shared by `stale?/2` (pid-based), the
  `:ping` close handler, `NodeProxy`'s consensus and eviction logic, and
  `ChainList.block_current?/2`.
  """
  def stale_at?(lastblock_at, chain, intervals \\ @stale_threshold_intervals) do
    cond do
      RemoteChain.frozen?(chain) ->
        false

      is_nil(lastblock_at) ->
        false

      true ->
        age = DateTime.diff(DateTime.utc_now(), lastblock_at, :second)
        age > chain.expected_block_intervall() * intervals
    end
  end

  @doc """
  The `lastblock_at` recorded in the WSConn state, or `nil` if the pid
  is not a live WSConn (dead, handshaking, or another process).

  Used by `NodeProxy` to evaluate eviction without depending on the
  private `try_get_state/1`.
  """
  def lastblock_at(pid) when is_pid(pid) do
    case try_get_state(pid) do
      %__MODULE__{lastblock_at: lastblock_at} -> lastblock_at
      _ -> nil
    end
  end

  def lastblock_at(_other), do: nil

  @doc """
  Whether the WSConn has stopped receiving block updates even though the
  underlying socket is still alive.

  A stale WSConn is excluded from `NodeProxy`'s block-number consensus and
  from the `pick_connection/1` rotation (it stays in the pool so it can
  recover without a restart) and is forcibly evicted after two ping
  cycles.

  Returns `false` for processes that are not `WSConn` instances or that
  cannot be inspected (dead, handshaking, mid-`sys.get_state` call).
  """
  def stale?(pid, chain) when is_pid(pid) do
    stale_at?(lastblock_at(pid), chain)
  end

  def stale?(_other, _chain), do: false

  def start(owner, chain, ws_url) do
    state = %__MODULE__{
      owner: owner,
      chain: chain,
      ws_url: ws_url,
      lastblock_at: DateTime.utc_now(),
      started_at: DateTime.utc_now()
    }

    {:ok, pid} =
      WebSockex.start(ws_url, __MODULE__, state,
        async: true,
        handle_initial_conn_failure: true,
        socket_connect_timeout: @connection_timeout_ms,
        socket_recv_timeout: @connection_timeout_ms
      )

    :timer.send_interval(:timer.seconds(chain.expected_block_intervall()) * 2, pid, :ping)
    pid
  end

  def close(pid) do
    WebSockex.cast(pid, :close)
  end

  @impl true
  def handle_cast(:close, state) do
    {:close, state}
  end

  @impl true
  def handle_connect(conn, state) do
    Process.monitor(state.owner)
    Globals.put({__MODULE__, self()}, conn)
    state = %{state | conn: conn}

    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "eth_subscribe",
      "params" => ["newHeads"]
    }
    |> Poison.encode!()
    |> send_frame(state)

    %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "eth_blockNumber",
      "params" => []
    }
    |> Poison.encode!()
    |> send_frame(state)

    {:ok, state}
  end

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    if reason != {:local, :normal} do
      Logger.warning(
        "WSConn disconnected from #{inspect(state.chain)} for reason: #{inspect(reason)} [#{inspect(state.ws_url)}]"
      )
    end

    clear_connection()
    {:ok, state}
  end

  @impl true
  def handle_frame(
        {:text, json},
        state = %{ws_url: ws_url, chain: _chain, subscription_id: subscription_id}
      ) do
    case Poison.decode!(json) do
      %{"id" => 1, "result" => subscription_id} when is_binary(subscription_id) ->
        {:ok, %{state | subscription_id: subscription_id}}

      %{"id" => 2, "result" => <<"0", _x, hex_number::binary>>} ->
        state = new_block(hex_number, nil, state)
        {:ok, state}

      %{
        "params" => %{
          "subscription" => ^subscription_id,
          "result" => %{"number" => <<"0", _x, hex_number::binary>>} = header
        }
      } ->
        state = new_block(hex_number, header, state)
        {:ok, state}

      %{"id" => _} = other ->
        send(state.owner, {:response, ws_url, other})
        {:ok, state}

      # Providers sometimes send bare error objects without `"id"` (e.g.
      # `%{"code" => -32603, "message" => "Internal server error"}`). Do not
      # crash the WSConn — that tears down the whole provider connection.
      other when is_map(other) ->
        Logger.warning("WSConn received unexpected JSON frame: #{inspect(other)}")
        {:ok, state}
    end
  end

  def handle_frame(other, state) do
    Logger.error("WSConn received unknown frame: #{inspect(other)}")
    {:ok, state}
  end

  def send_request(pid, request, timeout \\ 500) when is_pid(pid) and is_binary(request) do
    conn =
      try do
        Globals.await({__MODULE__, pid}, timeout)
      catch
        :exit, {:timeout, _} ->
          nil
      end

    if conn == nil do
      {:error, :not_connected}
    else
      {:ok, frame} = WebSockex.Frame.encode_frame({:text, request})
      WebSockex.Conn.socket_send(conn, frame)
    end
  end

  @doc """
  Non-blocking readiness check. Returns true iff `handle_connect/2` has
  already populated `Globals` with this WSConn's underlying connection
  (i.e. the TCP/TLS/WS handshake is done).

  Unlike `send_request/3`, this never blocks and never registers a waiter
  in `Globals`, so callers can use it to filter the connection pool
  without paying the 500&nbsp;ms `Globals.await` budget or producing
  noisy "Awaiting undefined key" / zombie-timeout log lines.
  """
  def ready?(pid) when is_pid(pid) do
    Globals.get({__MODULE__, pid}) != nil
  end

  def handshake_stale?(pid, timeout_ms \\ @connection_timeout_ms) when is_pid(pid) do
    Process.alive?(pid) and not ready?(pid) and handshake_age_ms(pid) > timeout_ms
  end

  def wsconn_process?(pid) when is_pid(pid) do
    match?(%WSConn{}, try_get_state(pid))
  end

  defp handshake_age_ms(pid) when is_pid(pid) do
    case try_get_state(pid) do
      %WSConn{started_at: started_at} ->
        DateTime.diff(DateTime.utc_now(), started_at, :millisecond)

      _ ->
        0
    end
  end

  defp try_get_state(pid) do
    try do
      :sys.get_state(pid, 1)
    catch
      :exit, _ -> nil
    end
  end

  defp clear_connection() do
    Globals.pop({__MODULE__, self()})
  end

  @impl true
  def handle_info(
        :ping,
        %WSConn{chain: chain, ws_url: ws_url} = state
      ) do
    if state.subscription_id == nil do
      raise "No subscription id received, aborting connection with #{ws_url}"
    end

    # Frozen chains: the staleness predicate can never be satisfied, so
    # skip it. The subscription_id check above still guards against a
    # WSConn that lost its `eth_subscribe("newHeads")` confirmation.
    cond do
      RemoteChain.frozen?(chain) ->
        {:ok, state}

      stale_at?(state.lastblock_at, chain) ->
        {:message_queue_len, len} = Process.info(self(), :message_queue_len)

        Logger.warning(
          "WSConn #{inspect({self(), len})} block timeout #{chain} (#{ws_url}). Restarting..."
        )

        {:close, state}

      true ->
        {:ok, state}
    end
  end

  defp new_block(hex_number, header, state) do
    block_number = String.to_integer(hex_number, 16)
    send(state.owner, {:new_block, state.ws_url, block_number, header})
    %{state | lastblock_at: DateTime.utc_now(), lastblock_number: block_number}
  end

  defp send_frame(request, state) do
    {:ok, frame} = WebSockex.Frame.encode_frame({:text, request})
    :ok = WebSockex.Conn.socket_send(state.conn, frame)
  end
end
