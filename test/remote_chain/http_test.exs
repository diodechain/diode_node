# Diode Server
# Copyright 2021-2026 Diode
# Licensed under the Diode License, Version 1.1
defmodule RemoteChain.HTTPTest do
  @moduledoc """
  Regression tests for `RemoteChain.HTTP` covering the HTTP call site
  formerly backed by HTTPoison (now Req): JSON-RPC result/error envelopes,
  gzip decompression, malformed bodies, transport failures, and the
  `send_raw_transaction/2` duplicate-transaction handling.
  """
  use ExUnit.Case, async: true

  # Stand-in for an EVM chain JSON-RPC provider.
  defmodule RpcPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      request = Poison.decode!(body)

      if test_pid = opts[:test_pid] do
        send(test_pid, {:rpc_request, request, conn.req_headers})
      end

      response = opts[:raw_body] || Poison.encode!(response_json(request, opts))
      response = if opts[:gzip], do: :zlib.gzip(response), else: response

      conn =
        conn
        |> put_resp_content_type("application/json")
        |> then(fn conn ->
          if opts[:gzip], do: put_resp_header(conn, "content-encoding", "gzip"), else: conn
        end)

      send_resp(conn, 200, response)
    end

    defp response_json(request, opts) do
      base = %{"jsonrpc" => "2.0", "id" => request["id"]}

      if error = opts[:error] do
        Map.put(base, "error", error)
      else
        Map.put(base, "result", opts[:result])
      end
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:plug_cowboy)
    {:ok, _} = Application.ensure_all_started(:req)
    :ok
  end

  describe "rpc/3" do
    test "returns {:ok, result} for a result envelope" do
      with_rpc([result: "0x7a69", test_pid: self()], fn url ->
        assert {:ok, "0x7a69"} = RemoteChain.HTTP.rpc(url, "eth_chainId", [])

        assert_received {:rpc_request, request, headers}
        assert request["jsonrpc"] == "2.0"
        assert request["method"] == "eth_chainId"
        assert request["params"] == []
        assert request["id"] == 1
        assert {"content-type", "application/json"} in headers
        assert Enum.any?(headers, fn {k, v} -> k == "accept-encoding" and v =~ "gzip" end)
      end)
    end

    test "returns {:error, error} for an error envelope" do
      error = %{"code" => -32000, "message" => "down"}

      with_rpc([error: error], fn url ->
        assert {:error, ^error} = RemoteChain.HTTP.rpc(url, "eth_chainId", [])
      end)
    end

    test "decompresses gzip responses" do
      with_rpc([gzip: true, result: %{"number" => "0x1"}], fn url ->
        assert {:ok, %{"number" => "0x1"}} =
                 RemoteChain.HTTP.rpc(url, "eth_getBlockByNumber", ["latest", false])
      end)
    end

    test "returns an error tuple for a non-JSON body" do
      with_rpc([raw_body: "not json"], fn url ->
        assert {:error, "Failed to decode response." <> _} =
                 RemoteChain.HTTP.rpc(url, "eth_chainId", [])
      end)
    end

    test "returns an error tuple for an empty body" do
      with_rpc([raw_body: ""], fn url ->
        assert {:error, "Failed to decode response." <> _} =
                 RemoteChain.HTTP.rpc(url, "eth_chainId", [])
      end)
    end

    test "returns an error tuple for envelopes without result or error key" do
      with_rpc([raw_body: Poison.encode!(%{"jsonrpc" => "2.0", "id" => 1})], fn url ->
        assert {:error, "Unexpected result" <> _} = RemoteChain.HTTP.rpc(url, "eth_chainId", [])
      end)
    end

    test "returns an error tuple when the provider is unreachable" do
      assert {:error, _reason} = RemoteChain.HTTP.rpc("http://127.0.0.1:1", "eth_chainId", [])
    end
  end

  describe "rpc!/3" do
    test "returns the result on success" do
      with_rpc([result: "0x1"], fn url ->
        assert "0x1" = RemoteChain.HTTP.rpc!(url, "eth_chainId", [])
      end)
    end

    test "raises on error" do
      with_rpc([error: %{"code" => -32000, "message" => "down"}], fn url ->
        assert_raise RuntimeError, ~r/RPC error/, fn ->
          RemoteChain.HTTP.rpc!(url, "eth_chainId", [])
        end
      end)
    end
  end

  describe "send_raw_transaction/2" do
    test "returns the transaction hash on success" do
      with_rpc([result: "0xabc", test_pid: self()], fn url ->
        assert "0xabc" = RemoteChain.HTTP.send_raw_transaction(url, "0xdeadbeef")

        assert_received {:rpc_request, request, _headers}
        assert request["method"] == "eth_sendRawTransaction"
        assert request["params"] == ["0xdeadbeef"]
      end)
    end

    test "maps -32603 'already known' to :already_known" do
      with_rpc(
        [error: %{"code" => -32603, "message" => "already known"}, test_pid: self()],
        fn url ->
          assert :already_known = RemoteChain.HTTP.send_raw_transaction(url, "0xdeadbeef")
        end
      )
    end

    test "maps -32000 duplicate transaction to :already_known" do
      with_rpc(
        [
          error: %{"code" => -32000, "message" => "duplicate transaction: 0xabc"},
          test_pid: self()
        ],
        fn url ->
          assert :already_known = RemoteChain.HTTP.send_raw_transaction(url, "0xdeadbeef")
        end
      )
    end

    test "raises on RPC errors without a -32603 or -32000 code" do
      with_rpc(
        [error: %{"code" => -32601, "message" => "method not found"}, test_pid: self()],
        fn url ->
          assert_raise RuntimeError, ~r/RPC error/, fn ->
            RemoteChain.HTTP.send_raw_transaction(url, "0xdeadbeef")
          end
        end
      )
    end

    test "returns the error tuple for other -32000 messages" do
      error = %{"code" => -32000, "message" => "nonce too low"}

      with_rpc(
        [error: error, test_pid: self()],
        fn url ->
          assert {:error, ^error} = RemoteChain.HTTP.send_raw_transaction(url, "0xdeadbeef")
        end
      )
    end
  end

  defp with_rpc(opts, fun) do
    ref = make_ref()
    {:ok, _pid} = Plug.Cowboy.http(RpcPlug, opts, port: 0, ref: ref)

    try do
      fun.("http://127.0.0.1:#{:ranch.get_port(ref)}")
    after
      Plug.Cowboy.shutdown(ref)
    end
  end
end
