# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.Rpc do
  require Logger
  alias DiodeClient.{Base16, Object, Object.Ticket, Rlp, Wallet}

  def handle_jsonrpc(rpcs, opts \\ [])

  def handle_jsonrpc(%{"_json" => rpcs}, opts) when is_list(rpcs) do
    handle_jsonrpc(rpcs, opts)
  end

  def handle_jsonrpc(rpcs, opts) when is_list(rpcs) do
    [head | rest] = Enum.chunk_every(rpcs, 100)

    tasks =
      Enum.map(rest, fn rpcs ->
        Task.async(fn ->
          Enum.map(rpcs, fn rpc ->
            {_status, body} = handle_jsonrpc(rpc, opts)
            body
          end)
        end)
      end)

    head_body =
      Enum.map(head, fn rpc ->
        {_status, body} = handle_jsonrpc(rpc, opts)
        body
      end)

    rest_body =
      Enum.flat_map(tasks, fn taskref ->
        Task.await(taskref, :infinity)
      end)

    {200, head_body ++ rest_body}
  end

  def handle_jsonrpc(body_params, opts) when is_map(body_params) do
    {id, method} =
      case body_params do
        %{"method" => method, "id" => id} -> {id, method}
        %{"id" => id} -> {id, ""}
        _other -> {0, ""}
      end

    params = Map.get(body_params, "params", [])

    {result, code, error} =
      try do
        execute_rpc(method, params, opts)
      rescue
        e in ErlangError ->
          Logger.error(
            "Network.Rpc: ErlangError #{inspect(e)} in #{inspect({method, params})}: #{inspect(__STACKTRACE__)}"
          )

          {nil, 400, %{"message" => "Bad Request"}}
      catch
        :notfound -> {nil, 404, %{"message" => "Not found"}}
        :badrequest -> {nil, 400, %{"message" => "Bad request"}}
      end

    if Diode.dev_mode?() do
      if method == "eth_getStorage" do
        Logger.info("#{method} = ...")
      else
        Logger.info("#{method} = #{inspect(result)}")
      end
    end

    {ret, code} =
      if error == nil do
        if not is_map(result) or not Map.has_key?(result, "error") do
          {%{"result" => result}, code}
        else
          {result, code}
        end
      else
        code = if code == 200, do: 400, else: code

        if not is_map(error) do
          {%{"error" => error}, code}
        else
          {error, code}
        end
      end

    envelope =
      %{"id" => {:raw, id}, "jsonrpc" => "2.0"}
      |> Map.merge(ret)
      |> Json.prepare!(big_x: false)

    {code, envelope}
  end

  defp execute([{true, {mod, fun}} | rest], args) do
    case apply(mod, fun, args) do
      nil -> execute(rest, args)
      other -> other
    end
  end

  defp execute([_ | rest], args) do
    execute(rest, args)
  end

  defp execute([], [method, params]) do
    Logger.info("Unhandled RPC: #{inspect({method, params})}")
    result(nil, 422, "Unsupported method")
  end

  def execute_rpc("", _params, _opts) do
    throw(:badrequest)
  end

  def execute_rpc(method, params, opts) do
    apis = [
      {true, {__MODULE__, :execute_std}},
      {true, {__MODULE__, :execute_dio}},
      {is_tuple(opts[:extra]), opts[:extra]}
    ]

    execute(apis, [method, params, opts])
  end

  def execute_std("eth_accounts", _params, _opts) do
    result([])
  end

  def execute_std("eth_getBalance", [address | _block], _opts)
      when address in ["what", "method?"] do
    result(nil, 400, "Bad request")
  end

  def execute_std(method, params, opts)
      when method in [
             "dio_accounts",
             "dio_codeGroups",
             "dio_supply",
             "dio_getPool",
             "eth_call",
             "eth_chainId",
             "eth_estimateGas",
             "eth_gasPrice",
             "eth_getBalance",
             "eth_getBlockByHash",
             "eth_getBlockByNumber",
             "eth_getCode",
             "eth_getCodeHash",
             "eth_getLogs",
             "eth_getTransactionByHash",
             "eth_getTransactionCount",
             "eth_getTransactionReceipt",
             "eth_sendRawTransaction",
             "net_version",
             "eth_pendingTransactions",
             "parity_pendingTransactions",
             "trace_block",
             "trace_replayBlockTransactions"
           ] do
    chain = RemoteChain.diode_l1_fallback()

    params =
      Enum.map(params, fn
        "latest" -> RemoteChain.peaknumber(chain)
        other -> other
      end)

    RemoteChain.RPCCache.rpc(chain, method, params)
    |> remote_rpc_result(method, opts)
  end

  def execute_std(method, params, _opts) do
    case method do
      "web3_clientVersion" ->
        result("Diode Relay Node " <> Diode.Version.description())

      "net_listening" ->
        result(true)

      "eth_getStorage" ->
        [address, ref] = params

        RemoteChain.RPCCache.get_storage(RemoteChain.diode_l1_fallback(), address, ref)
        |> result()

      "eth_getStorageAt" ->
        [address, location, ref] = params

        RemoteChain.RPCCache.get_storage_at(
          RemoteChain.diode_l1_fallback(),
          address,
          location,
          ref
        )
        |> result()

      "eth_blockNumber" ->
        RemoteChain.peaknumber(RemoteChain.diode_l1_fallback())
        |> result()

      "eth_syncing" ->
        result(false)

      "eth_mining" ->
        result(false)

      "eth_hashrate" ->
        result(0)

      "eth_acounts" ->
        result([])

      "eth_coinbase" ->
        result(Diode.address())

      "net_peerCount" ->
        peers = Network.Server.get_connections(Network.PeerHandlerV2)
        result(map_size(peers))

      "net_edgeCount" ->
        peers =
          map_size(Network.Server.get_connections(Network.EdgeV1)) +
            map_size(Network.Server.get_connections(Network.EdgeV2))

        result(peers)

      _ ->
        nil
    end
  end

  def execute_dio(method, params, _opts) do
    case method do
      "dio_edgev2" ->
        hd(params)
        |> Base16.decode()
        |> Rlp.decode!()
        |> Network.EdgeV2.handle_async_msg(nil)
        |> Rlp.encode!()
        |> Base16.encode()
        |> result()

      "dio_getObject" ->
        key = Base16.decode(hd(params))

        case KademliaLight.find_value(key) do
          nil -> result(nil, 404)
          binary -> result(Object.encode_list!(Object.decode!(binary)))
        end

      "dio_getNode" ->
        node = Base16.decode(hd(params))

        case KademliaLight.find_node_object(node) do
          nil -> result(nil, 404)
          object -> result(Object.encode_list!(object))
        end

      "dio_traffic" ->
        chain_id = Base16.decode_int(hd(params))
        peak = RemoteChain.peaknumber(chain_id)
        peak_epoch = RemoteChain.epoch(chain_id, peak)

        epoch =
          case params do
            [_chain_id, epoch] -> Base16.decode_int(epoch)
            [_chain_id] -> peak_epoch
          end

        block =
          if epoch == peak_epoch do
            peak
          else
            RemoteChain.chainimpl(chain_id).epoch_block(epoch)
          end

        fleets =
          TicketStore.tickets(chain_id, epoch)
          |> Enum.group_by(&Ticket.fleet_contract(&1))
          |> Enum.map(fn {fleet, tickets} ->
            {fleet,
             %{
               fleet: fleet,
               total_tickets: Enum.count(tickets),
               total_bytes: Enum.map(tickets, &Ticket.total_bytes/1) |> Enum.sum(),
               total_connections: Enum.map(tickets, &Ticket.total_connections/1) |> Enum.sum(),
               total_score: Enum.map(tickets, &Ticket.score/1) |> Enum.sum(),
               state: Contract.Registry.fleet(chain_id, fleet, encode16(block))
             }}
          end)
          |> Map.new()

        result(%{
          chain_id: chain_id,
          epoch: epoch,
          epoch_time:
            RemoteChain.blocktime(chain_id, RemoteChain.chainimpl(chain_id).epoch_block(epoch)),
          fleets: fleets
        })

      "dio_tickets" ->
        chain_id = Base16.decode_int(hd(params))
        peak = RemoteChain.peaknumber(chain_id)
        peak_epoch = RemoteChain.epoch(chain_id, peak)

        epoch =
          case params do
            [_chain_id, epoch] when is_integer(epoch) -> epoch
            [_chain_id, epoch] when is_binary(epoch) -> Base16.decode_int(epoch)
            [_chain_id] -> peak_epoch
          end

        tickets =
          TicketStore.tickets(chain_id, epoch)
          |> Enum.map(&Object.encode!/1)
          |> Enum.map(&Base16.encode/1)

        result(%{
          chain_id: chain_id,
          epoch: epoch,
          epoch_time:
            RemoteChain.blocktime(chain_id, RemoteChain.chainimpl(chain_id).epoch_block(epoch)),
          tickets: tickets
        })

      "dio_usage" ->
        incoming = Network.Stats.get(:edge_traffic_in)
        outgoing = Network.Stats.get(:edge_traffic_out)

        raw_result(%{
          address: Wallet.address!(Diode.wallet()) |> encode16(),
          name: Diode.Config.get("NAME"),
          uptime: encode16(Diode.uptime()),
          devices: encode16(map_size(Network.Server.get_connections(Network.EdgeV2))),
          incoming: encode16(incoming),
          outgoing: encode16(outgoing),
          total: encode16(incoming + outgoing)
        })

      "dio_usageHistory" ->
        [from, to, stepping] = params

        Network.Stats.get_history(from, to, stepping)
        |> Task.async_stream(fn {time, data} ->
          data =
            Enum.map(data, fn {key, value} ->
              key =
                case key do
                  key when is_atom(key) ->
                    Atom.to_string(key)

                  {key, nil} when is_atom(key) ->
                    "#{key}:nil"

                  {key, address} when is_atom(key) ->
                    "#{key}:#{encode16(address)}"
                end

              {key, value}
            end)
            |> Map.new()

          {time, data}
        end)
        |> Enum.reduce(%{}, fn {:ok, {key, value}}, acc ->
          Map.put(acc, key, value)
        end)
        |> raw_result()

      "dio_network" ->
        conns = Network.Server.get_connections(Network.PeerHandlerV2)

        connected =
          Enum.map(conns, fn {address, _conn} ->
            %{
              connected: true,
              last_seen: encode16(System.os_time(:second)),
              last_error: encode16(0),
              node_id: encode16(address),
              node:
                case Model.KademliaSql.object(Diode.hash(address)) do
                  nil ->
                    Logger.error("No object found for connected server #{encode16(address)}")
                    nil

                  object ->
                    Object.decode!(object)
                    |> Json.prepare!(big_x: false)
                end,
              retries: encode16(0)
            }
          end)
          |> Enum.filter(fn item -> item.node != nil end)

        KademliaLight.network()
        |> KBuckets.to_list()
        |> Enum.filter(fn item -> not KBuckets.is_self(item) end)
        |> Enum.map(fn item ->
          address = Wallet.address!(item.node_id)

          %{
            connected: Map.has_key?(conns, Wallet.address!(item.node_id)),
            last_seen: encode16(item.last_connected),
            last_error: encode16(item.last_error),
            node_id: encode16(address),
            node: Json.prepare!(KBuckets.object(item), big_x: false),
            retries: encode16(item.retries)
          }
        end)
        |> Enum.reverse()
        |> Enum.concat(connected)
        |> Enum.reduce(%{}, fn item, acc ->
          Map.put_new(acc, item.node_id, item)
        end)
        |> Map.values()
        |> raw_result()

      "dio_checkConnectivity" ->
        Connectivity.query_connectivity()
        |> result()

      "dio_proxy|" <> method ->
        handle_proxy(method, params, [])

      "dio_proxy2|" <> method ->
        handle_proxy(method, params, validate: true)

      _ ->
        nil
    end
  end

  defp handle_proxy(method, params, opts) do
    [node | params] = params
    node = Base16.decode(node)
    server = KademliaLight.find_node_object(node)

    cond do
      method not in [
        "dio_checkConnectivity",
        "dio_getObject",
        "dio_getNode",
        "dio_traffic",
        "dio_tickets",
        "dio_usage",
        "dio_usageHistory"
      ] ->
        result(nil, 400)

      server == nil ->
        result(nil, 404)

      true ->
        execute_proxy_request(node, server, method, params, opts)
    end
  end

  defp execute_proxy_request(node_id, server, method, params, opts) do
    host = if node_id == Diode.address(), do: "localhost", else: Object.Server.host(server)

    request = %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params,
      "id" => 1
    }

    HTTPoison.post("http://#{host}:8545", Poison.encode!(request), [
      {"Content-Type", "application/json"},
      {"Accept-Encoding", "gzip"}
    ])
    |> case do
      {:ok, %{body: ""}} ->
        result("")

      {:ok, %{body: body, headers: headers}} ->
        headers = Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end)

        body =
          if List.keyfind(headers, "content-encoding", 0) ==
               {"content-encoding", "gzip"} do
            :zlib.gunzip(body)
          else
            body
          end

        if opts[:validate] != true or validate_signature(node_id, body, headers) do
          body
          |> Poison.decode!()
          |> Map.get("result")
          |> raw_result()
        else
          result(nil, 400)
        end

      error = {:error, _reason} ->
        Logger.error("Error fetching #{method} from #{host}: #{inspect(error)}")
        result(nil, 502)
    end
  end

  defp validate_signature(node_id, body, headers) do
    node_id = Wallet.from_address(node_id)

    with {"x-diode-sender", sender} <- List.keyfind(headers, "x-diode-sender", 0),
         {"x-diode-signature", signature} <- List.keyfind(headers, "x-diode-signature", 0) do
      sender = Base16.decode(sender)

      Wallet.address!(node_id) == sender and
        Wallet.verify(node_id, "DiodeNodeReply" <> body, Base16.decode(signature))
    else
      _ ->
        false
    end
  end

  def decode_opts(opts) do
    Enum.map(opts, fn {key, value} ->
      value =
        case {key, value} do
          {_key, nil} -> nil
          {"to", _value} -> Base16.decode(value)
          {"from", _value} -> Base16.decode(value)
          {"data", _value} -> Base16.decode(value)
          {_key, _value} -> Base16.decode_int(value)
        end

      {key, value}
    end)
    |> Map.new()
  end

  defp raw_result(result, code \\ 200, error \\ nil) do
    {{:raw, result}, code, error}
  end

  defp result(result, code \\ 200, error \\ nil) do
    {result, code, error}
  end

  defp remote_rpc_result(%{"result" => %{"nonce" => _nonce} = result}, method, opts)
       when method in ["eth_getBlockByNumber", "eth_getBlockByHash"] do
    if opts[:strip_nonce] do
      result
      |> Map.put("nonce", "0x0000000000000000")
      |> Map.put(
        "logsBloom",
        "0x00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      )
    else
      result
    end
    |> result()
  end

  defp remote_rpc_result(result, _method, _opts) do
    case result do
      %{"message" => "Not found"} -> throw(:notfound)
      %{"result" => result} -> result(result)
      %{"error" => error} -> result(nil, 400, error)
    end
  end

  defp encode16(nil), do: nil
  defp encode16(value), do: Base16.encode(value, false)
end
