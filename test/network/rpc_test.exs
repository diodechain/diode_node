# Diode Server
# Copyright 2021-2026 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.RpcTest do
  @moduledoc """
  Regression tests for the `dio_proxy|*` / `dio_proxy2|*` node-to-node
  forwarding in `Network.Rpc`, covering the HTTP call site formerly backed
  by HTTPoison (now Req): JSON-RPC forwarding, gzip decompression, empty
  bodies, unreachable peers, and `dio_proxy2|` reply-signature validation.
  """
  use ExUnit.Case, async: false

  alias DiodeClient.Base16

  # Stand-in for a peer Diode node's JSON-RPC endpoint (port 8545 in
  # production) that `execute_proxy_request/5` forwards to.
  defmodule PeerNodePlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      request = Poison.decode!(body)

      if test_pid = opts[:test_pid] do
        send(test_pid, {:peer_request, request, conn.req_headers})
      end

      response = response_body(request, opts)

      conn =
        case opts[:sign] do
          :valid ->
            # Mirrors Network.RpcHttp: sign the (uncompressed) reply body
            signature = DiodeClient.Wallet.sign(Diode.wallet(), "DiodeNodeReply" <> response)

            conn
            |> put_resp_header("x-diode-signature", Base16.encode(signature))
            |> put_resp_header("x-diode-sender", DiodeClient.Wallet.base16(Diode.wallet()))

          :invalid ->
            conn
            |> put_resp_header("x-diode-signature", Base16.encode(<<1, 2, 3, 4>>))
            |> put_resp_header("x-diode-sender", DiodeClient.Wallet.base16(Diode.wallet()))

          _ ->
            conn
        end

      conn =
        if opts[:gzip] do
          conn |> put_resp_header("content-encoding", "gzip")
        else
          conn
        end

      body = if opts[:gzip], do: :zlib.gzip(response), else: response

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(opts[:status] || 200, body)
    end

    defp response_body(_request, opts) do
      if opts[:empty_body] do
        ""
      else
        Poison.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "result" => Keyword.get(opts, :result, %{"ok" => true})
        })
      end
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:plug_cowboy)
    {:ok, _} = Application.ensure_all_started(:req)
    :ok
  end

  test "dio_proxy| forwards the stripped method to the peer node and returns its result" do
    with_peer(
      [result: %{"ip" => "198.51.100.9", "ports" => []}, test_pid: self()],
      fn ->
        {status, envelope} = proxy_request("dio_proxy|dio_checkConnectivity")

        assert status == 200
        assert envelope["id"] == 7
        assert envelope["result"] == %{"ip" => "198.51.100.9", "ports" => []}

        assert_received {:peer_request, request, headers}
        assert request["jsonrpc"] == "2.0"
        assert request["method"] == "dio_checkConnectivity"
        assert request["params"] == []
        assert {"content-type", "application/json"} in headers
        assert Enum.any?(headers, fn {k, v} -> k == "accept-encoding" and v =~ "gzip" end)
      end
    )
  end

  test "dio_proxy| decompresses gzip responses from the peer node" do
    with_peer([gzip: true, result: %{"traffic" => 42}], fn ->
      {status, envelope} = proxy_request("dio_proxy|dio_traffic")

      assert status == 200
      assert envelope["result"] == %{"traffic" => 42}
    end)
  end

  test "dio_proxy| maps an empty peer response body to an empty string result" do
    with_peer([empty_body: true], fn ->
      {status, envelope} = proxy_request("dio_proxy|dio_checkConnectivity")

      assert status == 200
      # Json.prepare! hex-encodes empty binaries as "0x".
      assert envelope["result"] == "0x"
    end)
  end

  test "dio_proxy| returns 502 when the peer node is unreachable" do
    {:ok, _} = Application.ensure_all_started(:req)
    Application.put_env(:diode, :node_rpc_port, 1)
    on_exit(fn -> Application.delete_env(:diode, :node_rpc_port) end)

    {status, envelope} = proxy_request("dio_proxy|dio_checkConnectivity")

    assert status == 502
    assert envelope["result"] == nil
  end

  test "dio_proxy2| accepts a peer response signed by the requested node" do
    with_peer([sign: :valid, result: %{"traffic" => 42}], fn ->
      {status, envelope} = proxy_request("dio_proxy2|dio_traffic")

      assert status == 200
      assert envelope["result"] == %{"traffic" => 42}
    end)
  end

  test "dio_proxy2| rejects a peer response with an invalid signature" do
    with_peer([sign: :invalid, result: %{"traffic" => 42}], fn ->
      {status, envelope} = proxy_request("dio_proxy2|dio_traffic")

      assert status == 400
      assert envelope["result"] == nil
    end)
  end

  test "dio_proxy2| rejects a peer response without signature headers" do
    with_peer([result: %{"traffic" => 42}], fn ->
      {status, envelope} = proxy_request("dio_proxy2|dio_traffic")

      assert status == 400
      assert envelope["result"] == nil
    end)
  end

  # Forward a proxy request for this node itself so
  # `execute_proxy_request/5` targets `localhost:<mock port>`.
  defp proxy_request(method) do
    Network.Rpc.handle_jsonrpc(%{
      "jsonrpc" => "2.0",
      "id" => 7,
      "method" => method,
      "params" => [Base16.encode(Diode.address())]
    })
  end

  defp with_peer(opts, fun) do
    ref = {__MODULE__, :peer}
    {:ok, _pid} = Plug.Cowboy.http(PeerNodePlug, opts, port: 0, ref: ref)

    old = Application.get_env(:diode, :node_rpc_port)
    Application.put_env(:diode, :node_rpc_port, :ranch.get_port(ref))

    try do
      fun.()
    after
      Plug.Cowboy.shutdown(ref)

      if old do
        Application.put_env(:diode, :node_rpc_port, old)
      else
        Application.delete_env(:diode, :node_rpc_port)
      end
    end
  end
end
