# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.RpcWs do
  @behaviour :cowboy_websocket
  alias DiodeClient.{Base16, Random}
  require Logger

  @connection_state_methods ~w(
    dio_ticket
    dio_message
    dio_wireguard_open
    dio_wireguard_close
    dio_turn_open
  )

  def init(req, state) do
    {:cowboy_websocket, req, state, %{compress: true, idle_timeout: 60 * 60_000}}
  end

  def websocket_init(state) do
    PubSub.subscribe(:rpc)
    {:ok, state}
  end

  def websocket_handle({:ping, message}, state) do
    {:reply, {:pong, message}, state}
  end

  def websocket_handle(:ping, state) do
    {:reply, :pong, state}
  end

  def websocket_handle({:binary, message}, state) do
    websocket_handle({:text, message}, state)
  end

  def websocket_handle({:text, message}, state) do
    with {:ok, message} <- Poison.decode(message) do
      case message do
        %{"method" => method} when method in ["eth_subscribe", "eth_unsubscribe"] ->
          {_status, response} =
            Network.Rpc.handle_jsonrpc(message, extra: {__MODULE__, :execute_rpc})

          {:reply, {:text, Poison.encode!(response)}, state}

        _other ->
          if needs_connection_state?(message) do
            opts = [extra: {__MODULE__, :execute_rpc}, connection_state: true]
            {_status, response} = Network.Rpc.handle_jsonrpc(message, opts)
            {:reply, {:text, Poison.encode!(response)}, state}
          else
            pid = self()

            spawn_link(fn ->
              {_status, response} =
                Network.Rpc.handle_jsonrpc(message, extra: {__MODULE__, :execute_rpc})

              send(pid, {:reply, {:text, Poison.encode!(response)}})
            end)

            {:ok, state}
          end
      end
    else
      error ->
        Logger.error("Received invalid json #{inspect(error)}")
        {:reply, {:text, Poison.encode!("what?")}, state}
    end
  end

  defp needs_connection_state?(%{"method" => method})
       when method in @connection_state_methods,
       do: true

  defp needs_connection_state?(list) when is_list(list) do
    Enum.any?(list, &match?(%{"method" => m} when m in @connection_state_methods, &1))
  end

  defp needs_connection_state?(_), do: false

  def execute_rpc(method, params, _opts) do
    case method do
      "eth_subscribe" ->
        case params do
          ["newHeads", %{"includeTransactions" => includeTransactions}] ->
            subscribe({:block, includeTransactions})

          ["newHeads" | _] ->
            :ok
            subscribe({:block, false})

          ["syncing"] ->
            subscribe(:syncing)
        end

      "eth_unsubscribe" ->
        [id] = params

        ret =
          case Process.delete({:subs, id}) do
            nil -> false
            _ -> true
          end

        {ret, 200, nil}

      _ ->
        nil
    end
  end

  defp subscribe(what) do
    RemoteChain.NodeProxy.subscribe_block(RemoteChain.diode_l1_fallback())
    id = Base16.encode(Random.uint63h(), false)
    Process.put({:subs, id}, what)

    # Netowrk.Rpc.result() format
    {id, 200, nil}
  end

  def websocket_terminate(_terminate_reason, _arg1, _state) do
    Network.RpcWsTicketBilling.deactivate()
    :ok
  end

  def websocket_info({:reply, reply}, state) do
    {:reply, reply, state}
  end

  def websocket_info({:device_usage, device}, state) do
    Network.RpcWsTicketBilling.on_device_usage(device)
    {:ok, state}
  end

  def websocket_info(:rpc_ws_ticket_interval, state) do
    Network.RpcWsTicketBilling.on_interval()
    {:ok, state}
  end

  def websocket_info({:rpc_ws_ticket_deadline, required_version}, state) do
    case Network.RpcWsTicketBilling.on_deadline(required_version) do
      :close ->
        Logger.info("rpc_ws: closing websocket after dio_ticket_request deadline")
        {:stop, state}

      :ok ->
        {:ok, state}
    end
  end

  def websocket_info({:rpc_ws_push_notification, notification}, state) do
    reply_notification(notification, state)
  end

  def websocket_info({:send_message, payload, metadata}, state) do
    reply_notification(
      %{
        "jsonrpc" => "2.0",
        "method" => "dio_message_received",
        "params" => %{
          "payload" => Base16.encode(payload, false),
          "metadata" => metadata_map(metadata)
        }
      },
      state
    )
  end

  def websocket_info(any, state) do
    case any do
      {{RemoteChain.NodeProxy, _chain}, :block_number, block_number} ->
        reply =
          Enum.filter(Process.get(), fn
            {{:subs, _id}, {:block, _includeTransactions}} -> true
            _ -> false
          end)
          |> Enum.map(fn {{:subs, id}, {:block, includeTransactions}} ->
            {block, _, _} =
              Network.Rpc.execute_rpc(
                "eth_getBlockByNumber",
                [block_number, includeTransactions],
                []
              )

            {:text,
             Poison.encode!(%{
               "jsonrpc" => "2.0",
               "method" => "eth_subscription",
               "params" => %{
                 "subscription" => id,
                 "result" => Json.prepare!(block)
               }
             })}
          end)

        if reply != [] do
          {:reply, reply, state}
        else
          {:ok, state}
        end

      {:EXIT, _pid, :normal} ->
        {:ok, state}

      _ ->
        Logger.info("rpc_ws:websocket_info(#{inspect(any)})", [any])
        {:ok, state}
    end
  end

  defp reply_notification(notification, state) do
    {:reply, {:text, Poison.encode!(notification)}, state}
  end

  defp metadata_map(nil), do: %{}
  defp metadata_map(m) when is_map(m), do: m

  defp metadata_map(m) when is_list(m) do
    m
    |> Enum.filter(&match?([_k, _v], &1))
    |> Map.new(fn [k, v] -> {to_string(k), v} end)
  end

  defp metadata_map(_), do: %{}
end
