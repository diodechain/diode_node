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
    lastblock_number: 0
  ]

  def start(owner, chain, ws_url) do
    state = %__MODULE__{
      owner: owner,
      chain: chain,
      ws_url: ws_url,
      lastblock_at: DateTime.utc_now()
    }

    {:ok, pid} =
      WebSockex.start(ws_url, __MODULE__, state, async: true, handle_initial_conn_failure: true)

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
  def handle_disconnect(%{reason: {:local, :normal}}, state) do
    {:ok, state}
  end

  def handle_disconnect(%{reason: reason}, state) do
    Logger.warning(
      "WSConn disconnected from #{inspect(state.chain)} for reason: #{inspect(reason)} [#{inspect(state.ws_url)}]"
    )

    {:ok, state}
  end

  def handle_disconnect(status, state) do
    Logger.warning(
      "WSConn disconnected from #{inspect(state.chain)} for #{inspect(status)} [#{inspect(state.ws_url)}]"
    )

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
        state = new_block(hex_number, state)
        {:ok, state}

      %{
        "params" => %{
          "subscription" => ^subscription_id,
          "result" => %{"number" => <<"0", _x, hex_number::binary>>}
        }
      } ->
        state = new_block(hex_number, state)
        {:ok, state}

      %{"id" => _} = other ->
        send(state.owner, {:response, ws_url, other})
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

  @impl true
  def handle_info(
        :ping,
        %WSConn{chain: chain, lastblock_at: lastblock_at, ws_url: ws_url} = state
      ) do
    if state.subscription_id == nil do
      raise "No subscription id received, aborting connection with #{ws_url}"
    end

    age = DateTime.diff(DateTime.utc_now(), lastblock_at, :second)

    if age > chain.expected_block_intervall() * 10 do
      {:message_queue_len, len} = Process.info(self(), :message_queue_len)

      Logger.warning(
        "WSConn #{inspect({self(), len})} block timeout #{chain} (#{ws_url}). Restarting..."
      )

      {:close, state}
    else
      {:ok, state}
    end
  end

  defp new_block(hex_number, state) do
    block_number = String.to_integer(hex_number, 16)
    # Logger.info("WSConn received block #{block_number} from #{state.ws_url}")
    send(state.owner, {:new_block, state.ws_url, block_number})
    %{state | lastblock_at: DateTime.utc_now(), lastblock_number: block_number}
  end

  defp send_frame(request, state) do
    {:ok, frame} = WebSockex.Frame.encode_frame({:text, request})
    :ok = WebSockex.Conn.socket_send(state.conn, frame)
  end
end
