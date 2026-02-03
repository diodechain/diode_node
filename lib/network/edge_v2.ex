# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.EdgeV2 do
  use Network.Handler
  require Logger
  alias Network.PortCollection
  alias Network.PortCollection.Port
  alias DiodeClient.{Base16, Object, Object.Ticket}
  import DiodeClient.Object.TicketV1, only: :macros
  import DiodeClient.Object.TicketV2, only: :macros
  import DiodeClient.Object.Channel, only: :macros
  @refresh_interval :timer.hours(8)

  @type state :: %{
          blocked: :queue.queue(tuple()),
          compression: nil | :zlib,
          extra_flags: [],
          fleet: nil | binary(),
          inbuffer: nil | {integer(), binary()},
          last_message: DateTime.t(),
          last_ticket: nil | DateTime.t(),
          last_warning: nil | {:ticket, DateTime.t()},
          node_address: :inet.ip_address(),
          node_id: Wallet.t(),
          version: integer(),
          pid: pid(),
          ports: PortCollection.t(),
          sender: pid(),
          socket: any()
        }

  def do_init(state) do
    PubSub.subscribe({:edge, device_address(state)})

    state =
      Map.merge(state, %{
        blocked: :queue.new(),
        compression: nil,
        extra_flags: [],
        fleet: nil,
        inbuffer: nil,
        last_message: DateTime.utc_now(),
        last_ticket: nil,
        last_warning: nil,
        version: 0,
        pid: self(),
        ports: %PortCollection{pid: self()},
        sender: Network.Sender.new(state.socket)
      })

    log(state, "accepted connection")
    {:noreply, must_have_ticket(state)}
  end

  defp must_have_ticket(
         state = %{last_ticket: last, version: _version, last_warning: last_warning}
       ) do
    if last_warning != {:ticket, last} do
      Process.send_after(self(), {:must_have_ticket, last}, 20_000)

      %{state | last_warning: {:ticket, last}}
      |> send_ticket_request()
    else
      state
    end
  end

  defp send_ticket_request(state) do
    if state.version > 1_000 do
      msg =
        encode_request(random_ref(), [
          "ticket_request",
          TicketStore.device_usage(device_address(state))
        ])

      :ok = do_send_socket(state, :ticket, msg, nil)
      account_outgoing(state, msg)
    else
      state
    end
  end

  def ssl_options(opts) do
    Network.Server.default_ssl_options(opts)
    |> Keyword.put(:packet, :raw)
  end

  @impl true
  def handle_cast({:pccb_portopen, %Port{ref: ref, portname: portname}, device_address}, state) do
    state =
      send_socket(state, {:port, ref}, random_ref(), ["portopen", portname, ref, device_address])

    {:noreply, state}
  end

  def handle_cast({:pccb_portclose, %Port{ref: ref}}, state) do
    state = send_socket(state, {:port, ref}, random_ref(), ["portclose", ref])
    {:noreply, state}
  end

  def handle_cast(
        {:pccb2_portopen, portname, physical_port, source_device_address, flags},
        state
      ) do
    state =
      send_socket(state, {:port, physical_port}, random_ref(), [
        "portopen2",
        portname,
        physical_port,
        source_device_address,
        flags
      ])

    {:noreply, state}
  end

  def handle_cast({:pccb2_portclose, physical_port}, state) do
    state =
      send_socket(state, {:port, physical_port}, random_ref(), ["portclose2", physical_port])

    {:noreply, state}
  end

  def handle_cast(
        {:pccb_portsend, %Port{trace: trace, ref: ref}, data},
        state
      ) do
    trace = {trace, name(state), "exec portsend to #{Base16.encode(ref)}"}
    {:noreply, send_socket(state, {:port, ref}, random_ref(), ["portsend", ref, data], trace)}
  end

  def handle_cast({:send_socket, partition, request_id, result}, state) do
    {:noreply, send_socket(state, partition, request_id, result)}
  end

  def handle_cast({:trace, msg}, state) do
    {:noreply, send_socket(state, :trace, random_ref(), ["trace" | msg])}
  end

  def handle_cast(:stop, state) do
    log(state, "connection closed because of handshake anomaly.")
    {:stop, :normal, state}
  end

  @impl true
  def terminate(reason, state = %{sender: sender}) do
    if reason == :normal do
      Network.Sender.stop(sender)
    else
      log(state, "Received terminate: #{inspect(reason)}")
    end

    reason
  end

  def terminate(reason, state) do
    log(state, "Received terminate before init #{inspect({reason, state})}")
    reason
  end

  def handle_msg_tc(msg, state) do
    {time, ret} = :timer.tc(fn -> handle_msg(msg, state) end)
    time_ms = div(time, 1000)

    if ret != :async and time_ms > 3_000 do
      log(state, "Request took too long #{time_ms}ms: #{inspect(msg)}")
    end

    ret
  end

  def handle_msg(msg, state) do
    case msg do
      ["hello", vsn | flags] when is_binary(vsn) ->
        vsn = to_num(vsn)
        log(state, "hello #{vsn} #{inspect(flags)}")

        if vsn < 1_000 do
          {error("version not supported"), state}
        else
          state1 =
            Enum.reduce(flags, state, fn flag, state ->
              case flag do
                "zlib" -> %{state | compression: :zlib}
                other -> %{state | extra_flags: [other | state.extra_flags]}
              end
            end)

          # If compression has been enabled then on the next frame
          state =
            %{
              state
              | compression: state1.compression,
                extra_flags: state1.extra_flags,
                version: vsn
            }
            |> send_ticket_request()

          {response("ok"), state}
        end

      ["ticket", block, fleet, tc, tb, local_address, device_signature] ->
        ticketv1(
          server_id: Wallet.address!(Diode.wallet()),
          fleet_contract: fleet,
          total_connections: to_num(tc),
          total_bytes: to_num(tb),
          local_address: local_address,
          block_number: to_num(block),
          device_signature: device_signature
        )
        |> handle_ticket(state)

      ["ticketv2", chain_id, epoch, fleet, tc, tb, local_address, device_signature] ->
        ticketv2(
          chain_id: to_num(chain_id),
          server_id: Wallet.address!(Diode.wallet()),
          fleet_contract: fleet,
          total_connections: to_num(tc),
          total_bytes: to_num(tb),
          local_address: local_address,
          epoch: to_num(epoch),
          device_signature: device_signature
        )
        |> handle_ticket(state)

      ["bytes"] ->
        # This is an exception as unpaid_bytes can be negative
        {response(Rlpx.int2bin(unpaid_bytes(state))), state}

      ["portsend", ref, data] ->
        case PortCollection.portsend(state.ports, ref, data) do
          {:error, reason} -> error(reason)
          :ok -> response("ok")
        end

      # "portopen" response
      ["response", ref, "ok"] ->
        int_ref = Rlpx.bin2uint(ref)
        pid = Network.PortManager.port_find(int_ref)

        if pid do
          Network.PortManager.confirm_portopen(pid)
          {nil, state}
        else
          case PortCollection.confirm_portopen(state.ports, ref) do
            {:ok, ports} ->
              {nil, %{state | ports: ports}}

            {:error, reason} ->
              log(state, "ignoring response for #{inspect(reason)} from #{Base16.encode(ref)}")
              {nil, state}
          end
        end

      # "portopen" error
      ["error", ref, reason] ->
        int_ref = Rlpx.bin2uint(ref)
        pid = Network.PortManager.port_find(int_ref)

        if pid do
          Network.PortManager.deny_portopen(pid, reason)
          {nil, state}
        else
          {:ok, ports} = PortCollection.deny_portopen(state.ports, ref, reason)
          {nil, %{state | ports: ports}}
        end

      ["portclose2", physical_port] ->
        int_physical_port = Rlpx.bin2uint(physical_port)
        Network.PortManager.port_close(int_physical_port)
        {response("ok"), state}

      ["portclose", ref] ->
        case PortCollection.portclose(state.ports, ref) do
          {:error, reason} ->
            {error(reason), state}

          {:ok, ports} ->
            {response("ok"), %{state | ports: ports}}
        end

      [subscribe] ->
        chain =
          case String.split(subscribe, ":") do
            ["subscribe"] ->
              RemoteChain.diode_l1_fallback()

            [prefix, "subscribe"] ->
              Enum.find_value(RemoteChain.chains(), fn chain ->
                if prefix == chain.chain_prefix() do
                  chain
                end
              end)

            _ ->
              :async
          end

        if chain do
          RemoteChain.NodeProxy.subscribe_block(chain, trigger: true)
          response("ok")
        else
          error("invalid chain")
        end

      _other ->
        :async
    end
  end

  def handle_async_msg([cmd | rest] = msg, state) do
    chain =
      Enum.find(RemoteChain.chains(), fn chain ->
        prefix = chain.chain_prefix() <> ":"
        String.starts_with?(cmd, prefix)
      end)

    if chain do
      prefix = chain.chain_prefix() <> ":"
      cmd = binary_part(cmd, byte_size(prefix), byte_size(cmd) - byte_size(prefix))
      RemoteChain.Edge.handle_async_msg(chain, [cmd | rest], state)
    else
      case msg do
        [cmd | _rest]
        when cmd in [
               "getblock",
               "getblockquick",
               "getstateroots",
               "getaccount",
               "getaccountroot",
               "getaccountroots",
               "getaccountvalue",
               "getaccountvalues",
               "sendtransaction"
             ] ->
          msg = Rlp.encode!(msg) |> Base16.encode()

          RemoteChain.RPCCache.rpc!(RemoteChain.diode_l1_fallback(), "dio_edgev2", [msg])
          |> Base16.decode()
          |> Rlp.decode!()

        [cmd | _rest]
        when cmd in ["getblockquick2"] ->
          msg = Rlp.encode!(msg) |> Base16.encode()

          RemoteChain.RPC.rpc!(RemoteChain.diode_l1_fallback(), "dio_edgev2", [msg])
          |> Base16.decode()
          |> Rlp.decode!()

        [cmd | _] when cmd in ["getblockheader", "getblockheader2", "getblockpeak", "rpc"] ->
          RemoteChain.Edge.handle_async_msg(RemoteChain.diode_l1_fallback(), msg, state)

        ["ping"] ->
          response("pong")

        ["channel", chain_id, block_number, fleet, type, name, params, signature] ->
          obj =
            channel(
              chain_id: to_num(chain_id),
              server_id: Diode.wallet() |> Wallet.address!(),
              block_number: to_num(block_number),
              fleet_contract: fleet,
              type: type,
              name: name,
              params: params,
              signature: signature
            )

          device = Object.Channel.device_address(obj)

          cond do
            not Wallet.equal?(device, device_id(state)) ->
              error("invalid channel signature")

            not Contract.Fleet.device_allowlisted?(to_num(chain_id), fleet, device) ->
              error("device not whitelisted for this fleet")

            not Object.Channel.valid_type?(obj) ->
              error("invalid channel type")

            not Object.Channel.valid_params?(obj) ->
              error("invalid channel parameters")

            true ->
              key = Object.Channel.key(obj)

              case KademliaLight.find_value(key) do
                nil ->
                  KademliaLight.store(obj)
                  Object.encode_list!(obj)

                binary ->
                  Object.encode_list!(Object.decode!(binary))
              end
              |> response()
          end

        ["isonline", key] ->
          online = Map.get(Network.Server.get_connections(Network.EdgeV2), key) != nil
          response(online)

        ["getobject", key] ->
          with binary when binary != nil <- KademliaLight.find_value(key) do
            Object.encode_list!(Object.decode!(binary))
          end
          |> response()

        ["getnode", node] ->
          with object when object != nil <- KademliaLight.find_node_object(node) do
            Object.encode_list!(object)
          end
          |> response()

        ["getnodes", node] ->
          KademliaLight.find_nodes(node)
          |> Enum.map(&KBuckets.object?/1)
          |> Enum.filter(&(&1 != nil))
          |> Enum.map(&Object.encode_list!/1)
          |> response()

        ["portopen", device_id, port, flags] ->
          portopen(state, device_id, to_num(port), flags)

        ["portopen", device_id, port] ->
          portopen(state, device_id, to_num(port), "rw")

        ["portopen2", device_id, port, flags | _] ->
          Network.PortManager.request_portopen(port, device_address(state), device_id, flags)
          |> case do
            {:error, reason} -> error(reason)
            {:ok, physical_port} -> response("ok", physical_port)
          end

        _ ->
          log(state, "Unhandled message: #{truncate(msg)}")
          error(401, "bad input")
      end
    end
  end

  def handle_async_msg(msg, state) do
    log(state, "Unhandled message: #{truncate(msg)}")
    error(401, "bad input")
  end

  def response(arg) do
    response_array([arg])
  end

  def response(arg, arg2) do
    response_array([arg, arg2])
  end

  defp response_array(args) do
    ["response" | args]
  end

  def error(code, message) do
    ["error", code, message]
  end

  def error(message) do
    ["error", inspect(message)]
  end

  defp handle_packet(raw_msg, state) do
    state = account_incoming(state, raw_msg)
    msg = decode(state, raw_msg)

    # should be [request_id, method_params, opts]
    case msg do
      [request_id, method_params, opts] ->
        handle_request(state, to_num(request_id), method_params, opts)

      [request_id, method_params] ->
        handle_request(state, to_num(request_id), method_params, [])

      _other ->
        log(state, "connection closed because wrong message received.")
        {:stop, :normal, state}
    end
  end

  defp handle_data("", state) do
    {:noreply, state}
  end

  defp handle_data(<<0::unsigned-size(16), rest::binary>>, state = %{inbuffer: nil}) do
    handle_data(rest, state)
  end

  defp handle_data(<<length::unsigned-size(16), raw_msg::binary>>, state = %{inbuffer: nil}) do
    handle_data(length, raw_msg, state)
  end

  defp handle_data(<<more::binary>>, state = %{inbuffer: {length, buffer}}) do
    handle_data(length, buffer <> more, %{state | inbuffer: nil})
  end

  defp handle_data(length, raw_msg, state) do
    if byte_size(raw_msg) >= length do
      {:noreply, state} = handle_packet(binary_part(raw_msg, 0, length), state)
      rest = binary_part(raw_msg, length, byte_size(raw_msg) - length)
      handle_data(rest, %{state | inbuffer: nil})
    else
      {:noreply, %{state | inbuffer: {length, raw_msg}}}
    end
  end

  @impl true
  def handle_info({{RemoteChain.NodeProxy, chain}, :block_number, block_number}, state) do
    msg =
      encode_request(random_ref(), [
        "blockheader",
        chain.chain_id(),
        RemoteChain.Edge.get_block_header(chain, Rlpx.uint2bin(block_number))
      ])

    :ok = do_send_socket(state, :block_number, msg, nil)
    account_outgoing(state, msg)
    {:noreply, state}
  end

  def handle_info({:device_usage, _device}, state) do
    state =
      if unpaid_bytes(state) > send_threshold() do
        must_have_ticket(state)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info(:ticket_refresh, state) do
    {:noreply, must_have_ticket(state)}
  end

  def handle_info({:ssl, _socket, data}, state) do
    handle_data(data, %{state | last_message: DateTime.utc_now()})
  end

  def handle_info({:stop_unpaid, b0}, state) do
    log(state, "connection closed because unpaid #{b0}(#{unpaid_bytes(state)}) bytes.")
    {:stop, :normal, state}
  end

  def handle_info({:must_have_ticket, last}, state = %{last_ticket: timestamp}) do
    if timestamp == nil or timestamp == last do
      log(state, "connection closed because no valid ticket sent within time limit.")
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:ssl_closed, _}, state) do
    log(state, "connection closed by remote.")
    {:stop, :normal, state}
  end

  def handle_info(msg, state) do
    case PortCollection.maybe_handle_info(msg, state.ports) do
      ports = %PortCollection{} ->
        {:noreply, %{state | ports: ports}}

      false ->
        log(state, "Unhandled info: #{inspect(msg)}")
        {:noreply, state}
    end
  end

  defp handle_request(state, request_id, method_params, _opts) do
    case handle_msg_tc(method_params, state) do
      :async ->
        pid = self()

        spawn_link(fn ->
          result = handle_async_msg(method_params, state)
          result = encode_request(request_id, result)
          GenServer.cast(pid, {:send_socket, request_id, request_id, result})
        end)

        {:noreply, state}

      {result, state} ->
        {:noreply, send_socket(state, request_id, request_id, result)}

      result ->
        {:noreply, send_socket(state, request_id, request_id, result)}
    end
  end

  defp handle_ticket(dl, state) do
    cond do
      Ticket.epoch(dl) + 1 < RemoteChain.epoch(Ticket.chain_id(dl)) ->
        log(
          state,
          "Ticket with low epoch #{Ticket.epoch(dl)} vs. #{RemoteChain.epoch(Ticket.chain_id(dl))}!"
        )

        error("epoch number too low")

      Ticket.epoch(dl) > RemoteChain.epoch(Ticket.chain_id(dl)) ->
        log(
          state,
          "Ticket with wrong epoch #{Ticket.epoch(dl)} vs. #{RemoteChain.epoch(Ticket.chain_id(dl))}!"
        )

        error("epoch number too high")

      Ticket.too_many_bytes?(dl) ->
        log(state, "Ticket with too many bytes #{Ticket.total_bytes(dl)}!")
        error("too many bytes")

      Ticket.total_connections(dl) > 1024 * 1024 * 1024 * 1024 ->
        log(state, "Ticket with too many connections #{Ticket.total_connections(dl)}!")
        error("too many connections")

      not Ticket.device_address?(dl, device_id(state)) ->
        log(state, "Received invalid ticket signature!")
        error("signature mismatch")

      # TODO: Needs to be re-enabled after dev-contract is all-yes
      # not Contract.Fleet.device_allowlisted?(fleet, device) ->
      #   log(state, "Received invalid ticket fleet!")
      #   error("device not whitelisted")

      true ->
        dl = Ticket.server_sign(dl, Wallet.privkey!(Diode.wallet()))

        # If the version is 1000 and this is the first ticket of this session
        # we need to reset the device usage to the last ticket
        if state.version == 1000 and state.last_ticket == nil do
          last_ticket =
            TicketStore.find(device_address(state), Ticket.fleet_contract(dl), Ticket.epoch(dl))

          if last_ticket != nil do
            TicketStore.reset_device_usage(device_address(state), Ticket.total_bytes(last_ticket))
          else
            TicketStore.reset_device_usage(device_address(state), 0)
          end
        end

        ret = TicketStore.add(dl, device_id(state), state.version)
        total = Ticket.total_bytes(dl)
        usage = TicketStore.device_usage(device_address(state))
        log(state, "ticket total: #{total} usage: #{usage} ret => #{inspect(ret, limit: 32)}")

        case ret do
          {:ok, bytes} ->
            key = Object.key(dl)

            # Storing the updated ticket of this device, debounce is 15 sec
            Debouncer.immediate(
              key,
              fn ->
                Model.KademliaSql.put_object(KademliaLight.hash(key), Object.encode!(dl))
                KademliaLight.store(dl)
              end,
              15_000
            )

            # Storing the updated ticket of this device, debounce is 10 sec
            Diode.broadcast_self()
            pid = self()

            Debouncer.delay(
              {__MODULE__, :ticket_refresh, key},
              fn ->
                send(pid, :ticket_refresh)
              end,
              @refresh_interval
            )

            {response("thanks!", bytes),
             %{state | last_ticket: DateTime.utc_now(), fleet: Ticket.fleet_contract(dl)}}

          {:too_old, min} ->
            response("too_old", min)

          {:too_big_jump, min} ->
            response("too_big_jump", min)

          {:too_low, last} ->
            response_array(["too_low" | Ticket.summary(last)])
        end
    end
  end

  defp truncate(msg) when is_binary(msg) and byte_size(msg) > 40 do
    binary_part(msg, 0, 37) <> "..."
  end

  defp truncate(msg) when is_binary(msg) do
    msg
  end

  defp truncate(other) do
    :io_lib.format("~0p", [other])
    |> :erlang.iolist_to_binary()
    |> truncate()
  end

  defp portopen(state, <<channel_id::binary-size(32)>>, portname, flags) do
    ref = random_ref()
    trace = if String.contains?(flags, "t"), do: state.pid
    trace(trace, state, "received portopen for channel #{Base16.encode(ref)}")

    case KademliaLight.find_value(channel_id) do
      nil ->
        error("not found")

      bin ->
        channel = Object.decode!(bin)

        Object.Channel.server_id(channel)
        |> Wallet.from_address()
        |> Wallet.equal?(Diode.wallet())
        |> if do
          pid = Channels.ensure(channel)
          local_portopen(device_address(state), state.pid, portname, flags, pid, ref)
        else
          error("wrong host")
        end
    end
  end

  defp portopen(state, device_id, portname, flags) do
    trace = if String.contains?(flags, "t"), do: state.pid
    remote = String.contains?(flags, "p")

    ref = random_ref()
    address = device_address(state)
    trace(trace, state, "received portopen for #{Base16.encode(ref)}")

    with {:self, false} <- {:self, device_id == address},
         {:valid_flags, true} <- {:valid_flags, validate_flags(flags)},
         {:device_id, <<_::binary-size(20)>>} <- {:device_id, device_id} do
      case local_pid(device_id) || remote_pid(remote, device_id) do
        pid when is_pid(pid) ->
          local_portopen(address, state.pid, portname, flags, pid, ref)

        error ->
          error
      end
    else
      {:device_id, _} -> error("invalid device id")
      {:valid_flags, false} -> error("invalid flags")
      {:self, true} -> error("can't connect to yourself")
    end
  end

  defp local_pid(device_id) do
    PubSub.subscribers({:edge, device_id})
    |> List.first()
  end

  defp remote_pid(false, _device_id), do: error("not found")

  defp remote_pid(true, device_id) do
    case KademliaLight.find_value(device_id) do
      nil ->
        error("not found")

      binary ->
        tck = Object.decode!(binary)

        if Ticket.device_address(tck) != device_id do
          error("invalid ticket")
        else
          node_id = Wallet.from_address(Ticket.server_id(tck))
          server = KademliaLight.find_value(device_id) |> Object.decode!()

          Network.Server.ensure_node_connection(
            Network.PeerHandlerV2,
            node_id,
            Object.Server.host(server),
            Object.Server.peer_port(server)
          )
        end
    end
  end

  defp local_portopen(device_address, this, portname, flags, pid, ref) do
    case PortCollection.request_portopen(device_address, this, portname, flags, pid, ref) do
      {:error, reason} ->
        error(reason)

      :ok ->
        response("ok", ref)
    end
  end

  defp decode(state, msg) do
    case state.compression do
      nil -> msg
      :zlib -> :zlib.unzip(msg)
    end
    |> Rlp.decode!()
  end

  defp encode_request(request_id, msg) when is_list(msg) do
    Rlp.encode!([request_id, msg])
  end

  defp encode_request(_request_id, msg) when is_binary(msg) do
    # This is an optimization where we assume msg is already encoded
    msg
  end

  # defp is_portsend({:port, _}), do: true
  # defp is_portsend(_), do: false

  defp send_threshold() do
    Diode.ticket_grace() - Diode.ticket_grace() / 4
  end

  defp send_socket(state, partition, request_id, data, trace \\ nil) do
    if data == nil do
      account_outgoing(state)
    else
      %{state | blocked: :queue.in({partition, request_id, data}, state.blocked)}
    end
    |> flush_blocked(trace)
  end

  defp flush_blocked(state, trace) do
    if not :queue.is_empty(state.blocked) do
      {{:value, {partition, request_id, data}}, blocked} = :queue.out(state.blocked)
      state = %{state | blocked: blocked}
      msg = encode_request(request_id, data)
      :ok = do_send_socket(state, partition, msg, trace)
      account_outgoing(state, msg)
      flush_blocked(state, trace)
    else
      state
    end
  end

  defp do_send_socket(state, partition, msg, trace) do
    msg =
      case state.compression do
        nil -> msg
        :zlib -> :zlib.zip(msg)
      end

    length = byte_size(msg)

    Network.Sender.push_async(
      state.sender,
      partition,
      <<length::unsigned-size(16), msg::binary>>,
      trace
    )
  end

  @spec device_id(state()) :: Wallet.t()
  def device_id(%{node_id: id}), do: id
  def device_address(%{node_id: id}), do: Wallet.address!(id)
  @default_fleet DiodeClient.Base16.decode("0x8afe08d333f785c818199a5bdc7a52ac6ffc492a")
  def device_fleet(%{fleet: fleet}), do: fleet || @default_fleet

  defp account_incoming(state, msg) do
    [
      {:fleet_traffic_in, state.fleet},
      {:device_traffic_in, device_address(state)},
      :edge_traffic_in
    ]
    |> Enum.map(&{&1, byte_size(msg)})
    |> Network.Stats.batch_incr()

    TicketStore.increase_device_usage(device_address(state), byte_size(msg))
    state
  end

  defp account_outgoing(state, msg \\ "") do
    [
      {:fleet_traffic_out, state.fleet},
      {:device_traffic_out, device_address(state)},
      :edge_traffic_out
    ]
    |> Enum.map(&{&1, byte_size(msg)})
    |> Network.Stats.batch_incr()

    TicketStore.increase_device_usage(device_address(state), byte_size(msg))
    state
  end

  def on_nodeid(edge) do
    OnCrash.call(fn reason ->
      if reason != :kill_clone and reason != :normal do
        log({edge, nil}, "down for: #{inspect(reason)}")
      end
    end)

    :ok
  end

  defp to_num(bin) do
    Rlpx.bin2uint(bin)
  end

  defp to_bin(num) do
    Rlpx.uint2bin(num)
  end

  def trace(nil), do: :nop
  def trace({nil, _name, _format}), do: :nop

  def trace({trace, name, format}) do
    msg = [System.os_time(:millisecond), name, format]
    GenServer.cast(trace, {:trace, msg})
  end

  defp trace(nil, _state, _format), do: :nop

  defp trace(trace, state, format) do
    msg = [System.os_time(:millisecond), name(state), format]
    GenServer.cast(trace, {:trace, msg})
  end

  defp validate_flags(bytes) do
    flags = String.to_charlist(bytes)

    # flags must be a subset of "rwstp"
    # and must contain at least one of "r" or "w"
    Enum.all?(flags, fn
      ?r -> true
      ?w -> true
      ?s -> true
      ?t -> true
      ?p -> true
      _ -> false
    end) and (?r in flags or ?w in flags)
  end

  defp random_ref() do
    Random.uint31h()
    |> to_bin()
  end

  defp unpaid_bytes(state) do
    TicketStore.device_unpaid_bytes(device_address(state), device_fleet(state))
  end
end
