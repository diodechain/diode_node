# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.Rpc do
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
      Logger.info("#{method} = #{inspect(result)}")
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

  def execute_std(method, _params) do
    case method do
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

        case Kademlia.find_value(key) do
          nil -> result(nil, 404)
          binary -> result(Object.encode_list!(Object.decode!(binary)))
        end

      "dio_getNode" ->
        node = Base16.decode(hd(params))

        case Kademlia.find_node(node) do
          nil -> result(nil, 404)
          item -> result(Object.encode_list!(KBuckets.object(item)))
        end

      "dio_network" ->
        conns = Network.Server.get_connections(Network.PeerHandlerV2)

        Kademlia.network()
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
        |> result()

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
end
