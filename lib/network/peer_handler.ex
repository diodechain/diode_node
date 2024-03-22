# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.PeerHandler do
  use Network.Handler
  alias Object.Server, as: Server
  alias Model.KademliaSql

  # @hello 0
  # @response 1
  # @find_node 2
  # @find_value 3
  # @store 4
  # @publish 5
  @hello :hello
  @response :response
  @find_node :find_node
  @find_value :find_value
  @store :store

  @publish :publish
  @ping :ping
  @pong :pong

  def find_node, do: @find_node
  def find_value, do: @find_value
  def store, do: @store
  def publish, do: @publish
  def ping, do: @ping
  def pong, do: @pong

  def do_init(state) do
    send_hello(
      Map.merge(state, %{
        calls: :queue.new(),
        blocks: nil,
        random_blocks: 0,
        stable: false,
        msg_count: 0,
        start_time: System.os_time(:second),
        server: nil,
        job: nil,
        last_publish: nil,
        last_send: nil
      })
    )
  end

  def ssl_options(opts) do
    Network.Server.default_ssl_options(opts)
    |> Keyword.put(:packet, 4)
  end

  def handle_cast({:rpc, call}, state) do
    calls = :queue.in({call, nil}, state.calls)
    ssl_send(%{state | calls: calls}, call)
  end

  def handle_cast(:stop, state) do
    log(state, "connection closed because of handshake anomaly.")
    {:stop, :normal, state}
  end

  def handle_call({:rpc, call}, from, state) do
    calls = :queue.in({call, from}, state.calls)
    ssl_send(%{state | calls: calls}, call)
  end

  defp encode(msg) do
    BertInt.encode!(msg)
  end

  defp decode(msg) do
    BertInt.decode!(msg)
  end

  defp send_hello(state) do
    hostname =
      Diode.get_env("HOST", fn ->
        {:ok, {addr, _port}} = :ssl.sockname(state.socket)
        :erlang.list_to_binary(:inet.ntoa(addr))
      end)

    hello = Diode.self(hostname)
    # We don't have server registration atm
    chain_id = 0

    case ssl_send(state, [@hello, Object.encode!(hello), chain_id, []]) do
      {:noreply, state} ->
        receive do
          {:ssl, _socket, msg} ->
            msg = decode(msg)

            case hd(msg) do
              @hello ->
                handle_msg(msg, state)

              _ ->
                log(state, "expected hello message, but got #{inspect(msg)}")
                {:stop, :normal, state}
            end
        after
          3_000 ->
            log(state, "expected hello message, timeout")
            {:stop, :normal, state}
        end

      other ->
        other
    end
  end

  def handle_info({:ssl, _sock, omsg}, state) do
    msg = decode(omsg)

    # log(state, format("Received ~p bytes on ~p: ~180p", [byte_size(omsg), _sock, msg]))

    state = %{state | msg_count: state.msg_count + 1}

    # We consider this connection stable after at least 5 minutes and 10 messages
    state =
      if state.stable == false and
           state.msg_count > 10 and
           state.start_time + 300 < System.os_time(:second) do
        GenServer.cast(Kademlia, {:stable_node, state.node_id, state.server})
        %{state | stable: true}
      else
        state
      end

    case handle_msg(msg, state) do
      {reply, state} when not is_atom(reply) ->
        ssl_send(state, reply)

      other ->
        other
    end
  end

  def handle_info({:ssl_closed, info}, state) do
    log(state, "Connection closed by remote. info: #{inspect(info)}")
    {:stop, :normal, state}
  end

  def handle_info(msg, state) do
    log(state, "unhandled info: #{inspect(msg)}")
    {:noreply, state}
  end

  # Provides a `chain_id` for potential of checking server registration in the corresponding Diode Registry contract
  # `attr` is provided for future attributes, should be a kv-list
  defp handle_msg([@hello, server, _chain_id, _attr], state) do
    if Map.has_key?(state, :peer_port) do
      {:noreply, state}
    else
      server = Object.decode!(server)
      id = Wallet.address!(state.node_id)
      ^id = Object.key(server)

      port = Server.peer_port(server)

      log(state, "hello from: #{Wallet.printable(state.node_id)}")
      state = Map.put(state, :peer_port, port)
      GenServer.cast(Kademlia, {:register_node, state.node_id, server})
      {:noreply, %{state | server: server}}
    end
  end

  defp handle_msg([@find_node, id], state) do
    nodes =
      Kademlia.find_node_lookup(id)
      |> Enum.filter(fn node -> not KBuckets.is_self(node) end)
      |> map_network_items()

    {[@response, @find_node | nodes], state}
  end

  defp handle_msg([@find_value, id], state) do
    reply =
      case KademliaSql.object(id) do
        nil ->
          nodes =
            Kademlia.find_node_lookup(id)
            |> Enum.filter(fn node -> not KBuckets.is_self(node) end)
            |> map_network_items()

          [@response, @find_node | nodes]

        value ->
          [@response, @find_value, value]
      end

    {reply, state}
  end

  defp handle_msg([@store, key, value], state) do
    # Checks are made within KademliaSql
    KademliaSql.maybe_update_object(key, value)
    {[@response, @store, "ok"], state}
  end

  defp handle_msg([@ping], state) do
    {[@response, @ping, @pong], state}
  end

  defp handle_msg([@pong], state) do
    {[@response, @pong, @ping], state}
  end

  defp handle_msg([@response, @find_value, value], state) do
    respond(state, {:value, value})
  end

  defp handle_msg([@response, _cmd | rest], state) do
    respond(state, rest)
  end

  defp handle_msg(msg, state) do
    log(state, "Unhandled: #{inspect(msg)}")
    {:noreply, state}
  end

  defp respond(state, msg) do
    {{:value, {_call, from}}, calls} = :queue.out(state.calls)

    if from != nil do
      :ok = GenServer.reply(from, msg)
    end

    {:noreply, %{state | calls: calls}}
  end

  defp ssl_send(state = %{socket: socket, last_send: prev}, data) do
    raw = encode(data)

    case :ssl.send(socket, raw) do
      :ok ->
        {:noreply, %{state | last_send: data}}

      {:error, reason} ->
        :io.format("connection dropped for ~p last message I sent was: ~180p", [reason, prev])
        {:stop, :normal, state}
    end
  end

  def on_nodeid(nil) do
    :ok
  end

  def on_nodeid(node) do
    OnCrash.call(fn reason ->
      :io.format("Node ~p down for: ~180p~n", [Wallet.printable(node), reason])
      GenServer.cast(Kademlia, {:failed_node, node})
    end)
  end

  defp map_network_items(items) do
    Enum.map(items, &map_network_item/1)
  end

  defp map_network_item(
         item = %KBuckets.Item{
           last_connected: last_seen,
           node_id: node_id
         }
       ) do
    %{
      __struct__: KBuckets.Item,
      last_seen: last_seen,
      node_id: node_id,
      object: KBuckets.object(item),
      retries: 0
    }
  end
end
