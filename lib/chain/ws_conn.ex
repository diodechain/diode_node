defmodule Chain.WSConn do
  @moduledoc """
  Manage websocket connections to the given chain rpc node
  """
  use WebSockex
  require Logger

  defstruct [:chain, :conn, lastblock_at: DateTime.utc_now(), lastblock_number: 0]

  def start(chain, ws_url) do
    state = %__MODULE__{chain: chain}
    {:ok, pid} = WebSockex.start(ws_url, __MODULE__, state, async: true)
    :timer.send_interval(chain.expected_block_interval() * 2, pid, :ping)
    pid
  end

  @impl true
  def handle_connect(conn, state) do
    request =
      %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "eth_subscribe",
        "params" => ["newHeads"]
      }
      |> Jason.encode!()

    {:ok, binary_frame} = WebSockex.Frame.encode_frame({:text, request})
    WebSockex.Conn.socket_send(conn, binary_frame)
    {:ok, %{state | conn: conn}}
  end

  @impl true
  def handle_frame({:text, json}, state = %{chain: chain}) do
    case Jason.decode!(json) do
      %{"id" => 1, "result" => subscription_id} when is_binary(subscription_id) ->
        {:ok, state}

      %{"params" => %{"result" => %{"number" => hex_number}}} ->
        {:ok, state |> reset_poll_counter() |> broadcast(hex_number)}

      unexpected_response ->
        Logger.warning(
          "WSConn(#{chain}) received unexpected message: #{inspect(unexpected_response)}"
        )

        {:ok, state}
    end
  end

  @impl true
  def handle_info(:ping, %WSConn{chain: chain, lastblock_at: lastblock_at} = state) do
    if DateTime.diff(DateTime.utc_now(), lastblock_at, :millisecond) >
         chain.expected_block_intervall() * 2 do
      Logger.warning(
        "WSConn did not receive a block from (#{chain}) since double block interval. Restarting..."
      )

      {:close, state}
    else
      {:ok, state}
    end
  end
end
