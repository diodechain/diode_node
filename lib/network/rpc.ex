# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.Rpc do
  alias Object.Ticket
  require Logger

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
        {error, code}
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
    result("what method?", 422)
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

    execute(apis, [method, params])
  end

  def execute_std(method, params)
      when method in [
             "dio_edgev2",
             "dio_codeGroups",
             "dio_supply",
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
    |> remote_rpc_result()
  end

  def execute_std(method, params) do
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

  def execute_dio(method, params) do
    case method do
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
               state: Contract.Registry.fleet(chain_id, fleet, Base16.encode(block, false))
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

      "dio_usage" ->
        incoming = Network.Stats.get(:edge_traffic_in)
        outgoing = Network.Stats.get(:edge_traffic_out)

        result(%{
          address: Wallet.address!(Diode.wallet()) |> Base16.encode(),
          name: Diode.Config.get("NAME"),
          uptime: Diode.uptime(),
          devices: map_size(Network.Server.get_connections(Network.EdgeV2)),
          incoming: incoming,
          outgoing: outgoing,
          total: incoming + outgoing
        })

      "dio_usageHistory" ->
        [from, to, stepping] = params

        Network.Stats.get_history(from, to, stepping)
        |> Enum.map(fn {time, data} ->
          data =
            Enum.map(data, fn {key, value} ->
              key =
                case key do
                  key when is_atom(key) ->
                    Atom.to_string(key)

                  {key, nil} when is_atom(key) ->
                    "#{key}:nil"

                  {key, address} when is_atom(key) ->
                    "#{key}:#{Base16.encode(address)}"
                end

              {key, value}
            end)
            |> Map.new()

          {time, data}
        end)
        |> Map.new()
        |> result()

      "dio_network" ->
        conns = Network.Server.get_connections(Network.PeerHandlerV2)

        connected =
          Enum.map(conns, fn {address, _conn} ->
            %{
              connected: true,
              last_seen: System.os_time(:second),
              last_error: 0,
              node_id: address,
              node: Model.KademliaSql.object(Diode.hash(address)) |> Object.decode!(),
              retries: 0
            }
          end)

        KademliaLight.network()
        |> KBuckets.to_list()
        |> Enum.filter(fn item -> not KBuckets.is_self(item) end)
        |> Enum.map(fn item ->
          address = Wallet.address!(item.node_id)

          %{
            connected: Map.has_key?(conns, Wallet.address!(item.node_id)),
            last_seen: item.last_connected,
            last_error: item.last_error,
            node_id: address,
            node: KBuckets.object(item),
            retries: item.retries
          }
        end)
        |> Enum.concat(connected)
        |> Enum.reduce(%{}, fn item, acc ->
          Map.put_new(acc, item.node_id, item)
        end)
        |> Map.values()
        |> result()

      "dio_checkConnectivity" ->
        Connectivity.query_connectivity()
        |> result()

      "dio_proxy|" <> method ->
        [node | params] = params
        node = Base16.decode(node)

        if method not in [
             "dio_checkConnectivity",
             "dio_getObject",
             "dio_getNode",
             "dio_traffic",
             "dio_usage",
             "dio_usageHistory"
           ] do
          result(nil, 400)
        else
          case KademliaLight.find_node_object(node) do
            nil ->
              result(nil, 404)

            server ->
              host = Object.Server.host(server)

              request = %{
                "jsonrpc" => "2.0",
                "method" => method,
                "params" => params,
                "id" => 1
              }

              HTTPoison.post("http://#{host}:8545", Poison.encode!(request), [
                {"Content-Type", "application/json"}
              ])
              |> case do
                {:ok, %{body: body}} ->
                  json = Poison.decode!(body)
                  result(json["result"])

                error = {:error, _reason} ->
                  Logger.error("Error fetching #{method} from #{host}: #{inspect(error)}")
                  result(nil, 502)
              end
          end
        end

      _ ->
        nil
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

  def create_transaction(wallet, data, opts \\ %{}, sign \\ true) do
    # from = Wallet.address!(wallet)

    {gas, opts} = Map.pop(opts, "gas", 0x15F90)
    {value, opts} = Map.pop(opts, "value", 0x0)
    # blockRef = Map.get(opts, "blockRef", "latest")
    {chain_id, opts} = Map.pop(opts, "chainId")
    {nonce, opts} = Map.pop(opts, "nonce")
    {to, opts} = Map.pop(opts, "to")
    {gas_price, opts} = Map.pop(opts, "gasPrice", nil)

    if chain_id == nil do
      raise "Missing chainId"
    end

    gas_price =
      if gas_price == nil do
        RemoteChain.RPC.gas_price(chain_id)
        |> Base16.decode_int()
      else
        gas_price
      end

    nonce =
      if nonce == nil do
        RemoteChain.RPC.get_transaction_count(chain_id, Base16.encode(Wallet.address!(wallet)))
        |> Base16.decode_int()
      else
        nonce
      end

    if map_size(opts) > 0 do
      raise "Unhandled create_transaction(opts): #{inspect(opts)}"
    end

    tx = %RemoteChain.Transaction{
      to: to,
      nonce: nonce,
      gasPrice: gas_price,
      gasLimit: gas,
      init: if(to == nil, do: data),
      data: if(to != nil, do: data),
      value: value,
      chain_id: chain_id
    }

    if sign do
      RemoteChain.Transaction.sign(tx, Wallet.privkey!(wallet))
    else
      %{tx | signature: {:fake, Wallet.address!(wallet)}}
    end
  end

  defp result(result, code \\ 200, error \\ nil) do
    {result, code, error}
  end

  defp remote_rpc_result(result) do
    case result do
      %{"result" => result} -> result(result)
      %{"error" => error, "code" => code} -> result(nil, code, error)
      %{"message" => "Not found"} -> throw(:notfound)
    end
  end
end
