defmodule RemoteChain.ChainListTest do
  use ExUnit.Case, async: false

  @chain_id 1
  @other_chain_id 56
  @loaded_key {RemoteChain.ChainList, :loaded}

  # Minimal JSON-RPC server standing in for a chain provider over HTTP.
  defmodule MockChainRpcPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      %{"id" => id, "method" => method} = Poison.decode!(body)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Poison.encode!(rpc_reply(id, method, opts)))
    end

    defp rpc_reply(id, "eth_chainId", opts) do
      if opts[:chain_id_error] do
        %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => -32000, "message" => "down"}}
      else
        %{"jsonrpc" => "2.0", "id" => id, "result" => "0x7a69"}
      end
    end

    defp rpc_reply(id, "eth_getBlockByNumber", opts) do
      %{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{"number" => "0x1", "timestamp" => opts[:timestamp]}
      }
    end

    defp rpc_reply(id, _method, _opts) do
      %{"jsonrpc" => "2.0", "id" => id, "result" => nil}
    end
  end

  # Minimal JSON-RPC server standing in for a chain provider over WebSocket.
  # Answers the WSConn handshake (eth_subscribe, eth_blockNumber) plus the
  # eth_chainId / eth_getBlockByNumber probes sent by ChainList.do_test?/2.
  defmodule MockChainWsHandler do
    @behaviour :cowboy_websocket

    @impl true
    def init(req, opts) do
      {:cowboy_websocket, req, opts}
    end

    @impl true
    def websocket_handle({:text, json}, opts) do
      %{"id" => id, "method" => method} = Poison.decode!(json)

      result =
        case {id, method} do
          {1, "eth_subscribe"} -> "0x1"
          {2, "eth_blockNumber"} -> "0x10"
          {99, "eth_chainId"} -> "0x7a69"
          {100, "eth_getBlockByNumber"} -> %{"number" => "0x10", "timestamp" => opts[:timestamp]}
          _ -> nil
        end

      reply = Poison.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
      {:reply, {:text, reply}, opts}
    end

    @impl true
    def websocket_handle(_frame, opts), do: {:ok, opts}

    @impl true
    def websocket_info(_msg, opts), do: {:ok, opts}
  end

  setup do
    on_exit(&clear_chain_cache/0)
    clear_chain_cache()
    :ok
  end

  test "get/1 initializes globals cache on first access" do
    key = cache_key(@chain_id)
    assert Globals.get(key) == nil

    chain = RemoteChain.ChainList.get(@chain_id)

    assert chain["chainId"] == @chain_id
    assert is_list(chain["rpc"])
    assert Globals.get(key) == chain
  end

  test "get/1 primes all chains when any chain id is missing" do
    assert Globals.get(cache_key(@chain_id)) == nil
    assert Globals.get(cache_key(@other_chain_id)) == nil

    RemoteChain.ChainList.get(@chain_id)

    assert Globals.get(cache_key(@other_chain_id))["chainId"] == @other_chain_id
  end

  test "get/1 uses separate globals keys per chain id" do
    chain1 = RemoteChain.ChainList.get(@chain_id)
    chain56 = RemoteChain.ChainList.get(@other_chain_id)

    assert Globals.get(cache_key(@chain_id)) == chain1
    assert Globals.get(cache_key(@other_chain_id)) == chain56
    assert chain1["chainId"] == @chain_id
    assert chain56["chainId"] == @other_chain_id
  end

  test "get/1 does not reload file for unknown chain ids" do
    assert RemoteChain.ChainList.get(9_999_999_999) == nil
    assert RemoteChain.ChainList.get(9_999_999_999) == nil
    assert Globals.get(@loaded_key) == true
  end

  test "get/1 prefers chains.json in data dir when present" do
    path = Diode.data_dir("chains.json")
    File.mkdir_p!(Path.dirname(path))

    custom_chain = %{
      "chainId" => 99_999,
      "name" => "custom-test-chain",
      "rpc" => [%{"url" => "https://example.invalid/rpc"}]
    }

    File.write!(path, Jason.encode!([custom_chain]))

    on_exit(fn ->
      File.rm(path)
      clear_chain_cache()
    end)

    assert RemoteChain.ChainList.get(99_999) == custom_chain
  end

  test "refresh_chains/1 updates cached chain ids without priming uncached entries" do
    chain = RemoteChain.ChainList.get(@chain_id)
    key = cache_key(@chain_id)
    uncached_chain_id = 9_999_999_998
    uncached_key = cache_key(uncached_chain_id)

    Globals.put(key, Map.put(chain, "name", "stale"))

    updated_chain = Map.put(chain, "name", "updated")
    uncached_chain = %{"chainId" => uncached_chain_id, "name" => "new", "rpc" => []}

    RemoteChain.ChainList.refresh_chains([updated_chain, uncached_chain])

    assert Globals.get(key)["name"] == "updated"
    assert Globals.get(uncached_key) == nil
  end

  describe "block_current?/2" do
    test "accepts a block with a fresh timestamp" do
      assert RemoteChain.ChainList.block_current?(Chains.Anvil, %{
               "timestamp" => hex_timestamp(System.os_time(:second))
             })
    end

    test "rejects a provider whose latest block stopped updating" do
      stale = System.os_time(:second) - 24 * 3600

      refute RemoteChain.ChainList.block_current?(Chains.Anvil, %{
               "timestamp" => hex_timestamp(stale)
             })
    end

    test "rejects blocks without a decodable timestamp" do
      refute RemoteChain.ChainList.block_current?(Chains.Anvil, %{})
      refute RemoteChain.ChainList.block_current?(Chains.Anvil, nil)
    end

    test "max_block_age_seconds scales with the chain's block interval" do
      assert RemoteChain.ChainList.max_block_age_seconds(Chains.Anvil) == 150
      assert RemoteChain.ChainList.max_block_age_seconds(Chains.OasisSapphire) == 60
    end
  end

  describe "timestamp_current?/2" do
    test "accepts blocks within max age, rejects older ones" do
      now = System.os_time(:second)

      assert RemoteChain.ChainList.timestamp_current?(150, now)
      assert RemoteChain.ChainList.timestamp_current?(150, now - 150)
      refute RemoteChain.ChainList.timestamp_current?(150, now - 151)
    end

    test "accepts limited future clock skew, rejects beyond it" do
      now = System.os_time(:second)

      assert RemoteChain.ChainList.timestamp_current?(150, now + 60)
      refute RemoteChain.ChainList.timestamp_current?(150, now + 61)
    end
  end

  describe "do_test?/2 HTTP providers" do
    test "accepts a provider serving current blocks" do
      with_http_mock([timestamp: hex_timestamp(System.os_time(:second))], fn url ->
        assert RemoteChain.ChainList.do_test?(url, Chains.Anvil)
      end)
    end

    test "rejects a provider that answers eth_chainId but stopped providing new blocks" do
      # Regression: some Oasis providers keep responding to RPC while stuck on
      # an old block height. eth_chainId alone used to pass the filter.
      with_http_mock([timestamp: hex_timestamp(System.os_time(:second) - 24 * 3600)], fn url ->
        refute RemoteChain.ChainList.do_test?(url, Chains.Anvil)
      end)
    end

    test "rejects a provider that fails eth_chainId" do
      with_http_mock([chain_id_error: true], fn url ->
        refute RemoteChain.ChainList.do_test?(url, Chains.Anvil)
      end)
    end
  end

  describe "do_test?/2 WS providers" do
    test "accepts a provider serving current blocks" do
      with_ws_mock([timestamp: hex_timestamp(System.os_time(:second))], fn url ->
        assert RemoteChain.ChainList.do_test?(url, Chains.Anvil)
      end)
    end

    test "rejects a provider that answers eth_chainId but stopped providing new blocks" do
      with_ws_mock([timestamp: hex_timestamp(System.os_time(:second) - 24 * 3600)], fn url ->
        refute RemoteChain.ChainList.do_test?(url, Chains.Anvil)
      end)
    end
  end

  describe "test?/2 caching" do
    test "caches the verdict and does not re-probe within the TTL" do
      with_http_mock([timestamp: hex_timestamp(System.os_time(:second))], fn url ->
        assert RemoteChain.ChainList.test?(url, Chains.Anvil) == true

        # Verdict is stored with a monotonic probe timestamp.
        assert {true, tested_at} = Globals.get({RemoteChain.ChainList, :test, url})
        assert is_integer(tested_at)

        # Stop the mock: a cached verdict must be served without probing.
        Plug.Cowboy.shutdown(mock_ref())
        assert RemoteChain.ChainList.test?(url, Chains.Anvil) == true
      end)
    end

    test "rejects a stale provider through the cached test? entry" do
      with_http_mock([timestamp: hex_timestamp(System.os_time(:second) - 24 * 3600)], fn url ->
        assert RemoteChain.ChainList.test?(url, Chains.Anvil) == false
        assert {false, _tested_at} = Globals.get({RemoteChain.ChainList, :test, url})
      end)
    end
  end

  defp mock_ref(), do: {__MODULE__, :current_mock}

  defp hex_timestamp(seconds), do: "0x" <> Integer.to_string(seconds, 16)

  defp with_http_mock(opts, fun) do
    {:ok, _} = Application.ensure_all_started(:plug_cowboy)
    # Needed for DIODE_MINIMAL_TEST runs where the app (and its hackney HTTP
    # client) is not started.
    {:ok, _} = Application.ensure_all_started(:httpoison)
    ref = mock_ref()

    {:ok, _pid} = Plug.Cowboy.http(MockChainRpcPlug, opts, port: 0, ref: ref)

    try do
      fun.("http://127.0.0.1:#{:ranch.get_port(ref)}")
    after
      Plug.Cowboy.shutdown(ref)
    end
  end

  defp with_ws_mock(opts, fun) do
    {:ok, _} = Application.ensure_all_started(:cowboy)
    ref = mock_ref()

    dispatch = :cowboy_router.compile([{:_, [{:_, MockChainWsHandler, opts}]}])

    {:ok, _pid} = :cowboy.start_clear(ref, [port: 0], %{env: %{dispatch: dispatch}})

    try do
      fun.("ws://127.0.0.1:#{:ranch.get_port(ref)}")
    after
      :cowboy.stop_listener(ref)
    end
  end

  defp cache_key(chain_id), do: {RemoteChain.ChainList, chain_id}

  defp clear_chain_cache() do
    Globals.pop(@loaded_key)

    Enum.each([@chain_id, @other_chain_id, 99_999], fn chain_id ->
      Globals.pop(cache_key(chain_id))
    end)
  end
end
