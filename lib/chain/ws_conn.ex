# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Chain.WSConn do
  @moduledoc """
  Manage websocket connections to the given chain rpc node
  """
  use WebSockex
  alias Chain.WSConn
  require Logger

  defstruct [
    :owner,
    :chain,
    :ws_url,
    :conn,
    :lastblock_at,
    lastblock_number: 0
  ]

  def start(owner, chain, ws_url) do
    state = %__MODULE__{
      owner: owner,
      chain: chain,
      ws_url: ws_url,
      lastblock_at: DateTime.utc_now()
    }

    {:ok, pid} = WebSockex.start(ws_url, __MODULE__, state, async: true)
    :timer.send_interval(chain.expected_block_intervall() * 2, pid, :ping)
    pid
  end

  @impl true
  def handle_connect(conn, state) do
    Process.monitor(state.owner)

    request =
      %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "eth_subscribe",
        "params" => ["newHeads"]
      }
      |> Poison.encode!()

    {:ok, binary_frame} = WebSockex.Frame.encode_frame({:text, request})
    WebSockex.Conn.socket_send(conn, binary_frame)
    {:ok, %{state | conn: conn}}
  end

  @impl true
  def handle_frame({:text, json}, state = %{ws_url: ws_url, chain: chain}) do
    if chain == Chains.Diode do
      IO.inspect(Poison.decode!(json), label: "#{chain}")
    end

    case Poison.decode!(json) do
      %{"id" => 1, "result" => subscription_id} when is_binary(subscription_id) ->
        {:ok, state}

      %{"id" => _} = other ->
        send(state.owner, {:response, ws_url, other})
        {:ok, state}

      %{"params" => %{"result" => %{"number" => hex_number}}} ->
        block_number = String.to_integer(hex_number, 16)
        send(state.owner, {:new_block, ws_url, block_number})
        {:ok, %{state | lastblock_at: DateTime.utc_now(), lastblock_number: block_number}}
    end
  end

  @impl true
  # Chain.RPC.block_number(Chains.Diode)
  def handle_cast({:send_request, request}, state) do
    IO.inspect("Sending frame: #{inspect(request)}")
    {:ok, frame} = WebSockex.Frame.encode_frame({:text, request})
    WebSockex.Conn.socket_send(state.conn, frame)
    {:noreply, state}
  end

  @impl true
  def handle_info(
        :ping,
        %WSConn{chain: chain, lastblock_at: lastblock_at, ws_url: ws_url} = state
      ) do
    age = DateTime.diff(DateTime.utc_now(), lastblock_at, :second)

    if age > chain.expected_block_intervall() * 2 do
      # IO.inspect({lastblock_at, DateTime.utc_now(), age, chain.expected_block_intervall() * 2})
      Logger.warning(
        "WSConn did not receive a block from #{chain} (#{ws_url}) since double block interval. Restarting..."
      )

      {:close, state}
    else
      {:ok, state}
    end
  end
end
