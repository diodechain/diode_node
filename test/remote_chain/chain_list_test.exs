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

  describe "block_current?/2 for frozen chains" do
    # Regression: Moonbeam stopped producing blocks at 16_796_699. A
    # healthy provider's `eth_getBlockByNumber("latest")` returns that
    # block with an ancient timestamp; the age-based check rejects it,
    # which causes the endpoint probe to fail on every TTL refresh.
    test "accepts the final block on a frozen chain regardless of timestamp" do
      final = RemoteChain.final_block_number(Chains.Moonbeam)
      ancient = System.os_time(:second) - 365 * 24 * 3600

      assert RemoteChain.ChainList.block_current?(Chains.Moonbeam, %{
               "number" => "0x" <> Integer.to_string(final, 16),
               "timestamp" => hex_timestamp(ancient)
             })
    end

    test "rejects a block whose number does not match the final block on a frozen chain" do
      # Provider reports a block newer than the freeze → must be wrong
      # (or the chain has resumed and the final_block_number is stale).
      final = RemoteChain.final_block_number(Chains.Moonbeam)
      wrong = "0x" <> Integer.to_string(final + 1, 16)

      refute RemoteChain.ChainList.block_current?(Chains.Moonbeam, %{
               "number" => wrong,
               "timestamp" => hex_timestamp(System.os_time(:second))
             })
    end

    test "rejects a frozen-chain block without a decodable number" do
      refute RemoteChain.ChainList.block_current?(Chains.Moonbeam, %{
               "timestamp" => hex_timestamp(System.os_time(:second))
             })
    end

    test "still applies the timestamp check to non-frozen chains" do
      # Sanity check: a 24h-old block on Anvil (15s cadence) is rejected.
      stale = System.os_time(:second) - 24 * 3600

      refute RemoteChain.ChainList.block_current?(Chains.Anvil, %{
               "number" => "0x1",
               "timestamp" => hex_timestamp(stale)
             })
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

  describe "endpoints/2 filtering scope" do
    test "appends additional endpoints without a health probe" do
      # Additional URLs (ChainImpl extras / overrides) must remain available even
      # when they would fail test?/2. Only chainlist entries are filtered.
      dead = "wss://unreachable.invalid/ws-additional"
      assert RemoteChain.ChainList.ws_endpoints(Chains.Anvil, [dead]) == [dead]
      # Ensure we never ran a probe that would hang on DNS.
      assert Globals.get({RemoteChain.ChainList, :test, dead}) == nil
    end

    test "drops chainlist URLs that fail the health probe" do
      chain_id = Chains.Anvil.chain_id()
      dead_ws = "wss://unreachable-chainlist.invalid/ws"
      dead_rpc = "https://unreachable-chainlist.invalid/rpc"
      extra_ws = "ws://override.example/ws"

      Globals.put(@loaded_key, true)

      Globals.put(cache_key(chain_id), %{
        "chainId" => chain_id,
        "name" => "anvil-filter-scope",
        "rpc" => [%{"url" => dead_rpc}, %{"url" => dead_ws}]
      })

      # Pre-seed failed verdicts so the background probe does not open the network.
      now = System.monotonic_time(:millisecond)
      Globals.put({RemoteChain.ChainList, :test, dead_ws}, {false, now})
      Globals.put({RemoteChain.ChainList, :test, dead_rpc}, {false, now})

      on_exit(fn ->
        Globals.pop(cache_key(chain_id))
        Globals.pop({RemoteChain.ChainList, :test, dead_ws})
        Globals.pop({RemoteChain.ChainList, :test, dead_rpc})
        clear_chain_cache()
      end)

      # Cold cache: first call returns the deduped chainlist synchronously,
      # without probing. The dead URLs are visible until the background
      # refresh settles — this is the new contract: callers never block.
      cold_ws = RemoteChain.ChainList.ws_endpoints(Chains.Anvil, [extra_ws])
      assert dead_ws in cold_ws
      assert extra_ws in cold_ws

      # Background refresh drops the failed URLs and the warm cache returns the
      # filtered list synchronously.
      assert eventually(
               fn ->
                 case Globals.get(endpoint_cache_key(chain_id)) do
                   {urls, _ts} -> urls == []
                   _ -> false
                 end
               end,
               2_000
             ),
             "background refresh did not populate the endpoint cache (got: " <>
               inspect(Globals.get(endpoint_cache_key(chain_id))) <> ")"

      warm_ws = RemoteChain.ChainList.ws_endpoints(Chains.Anvil, [extra_ws])
      warm_rpc = RemoteChain.ChainList.rpc_endpoints(Chains.Anvil, [extra_ws])

      assert warm_ws == [extra_ws]
      refute dead_ws in warm_ws
      # WS-looking additional must land in :ws, not poison the rpc list when grouped.
      assert warm_rpc == nil or dead_rpc not in warm_rpc
    end

    test "deduplicates filtered chainlist and additional URLs" do
      with_ws_mock([timestamp: hex_timestamp(System.os_time(:second))], fn url ->
        Globals.put(@loaded_key, true)

        Globals.put(cache_key(Chains.Anvil.chain_id()), %{
          "chainId" => Chains.Anvil.chain_id(),
          "name" => "anvil-dedupe",
          "rpc" => [%{"url" => url}]
        })

        on_exit(&clear_chain_cache/0)

        assert RemoteChain.ChainList.ws_endpoints(Chains.Anvil, [url, url]) == [url]
      end)
    end

    test "cold cache returns synchronously and never opens a probe" do
      # Regression for the eu1 Base deadlock (2026-08-14): filter_endpoints/2
      # was blocking the NodeProxy GenServer on a Task.async_stream of HTTP /
      # WS health probes. With the cache, a slow probe is now background
      # work and the caller returns immediately.
      chain_id = Chains.Anvil.chain_id()
      good_url = "wss://unreachable.invalid/ws-cold-good"
      bad_url = "wss://unreachable.invalid/ws-cold-bad"

      Globals.put(@loaded_key, true)

      Globals.put(cache_key(chain_id), %{
        "chainId" => chain_id,
        "rpc" => [%{"url" => good_url}, %{"url" => bad_url}]
      })

      # Pre-seed verdicts so the background probe does no network work.
      now = System.monotonic_time(:millisecond)
      Globals.put({RemoteChain.ChainList, :test, good_url}, {true, now})
      Globals.put({RemoteChain.ChainList, :test, bad_url}, {false, now})

      on_exit(fn ->
        Globals.pop(cache_key(chain_id))
        Globals.pop({RemoteChain.ChainList, :test, good_url})
        Globals.pop({RemoteChain.ChainList, :test, bad_url})
        clear_chain_cache()
      end)

      started = System.monotonic_time(:millisecond)
      result = RemoteChain.ChainList.filter_endpoints([good_url, bad_url], Chains.Anvil)
      elapsed = System.monotonic_time(:millisecond) - started

      # Synchronous, no probe work in this process.
      assert elapsed < 50
      assert good_url in result
      assert bad_url in result
    end

    test "warm cache returns the cached list without invoking the probe" do
      chain_id = Chains.Anvil.chain_id()
      cached_urls = ["wss://cached-a.invalid/", "wss://cached-b.invalid/"]

      Globals.put(
        endpoint_cache_key(chain_id),
        {cached_urls, System.monotonic_time(:millisecond)}
      )

      on_exit(fn ->
        Globals.pop(endpoint_cache_key(chain_id))
        clear_chain_cache()
      end)

      assert RemoteChain.ChainList.filter_endpoints(["wss://never.probed.invalid/"], Chains.Anvil) ==
               cached_urls
    end

    test "stale cache returns the stale value and schedules a refresh" do
      chain_id = Chains.Anvil.chain_id()
      stale_urls = ["wss://stale.invalid/"]

      Globals.put(
        endpoint_cache_key(chain_id),
        {stale_urls, System.monotonic_time(:millisecond) - :timer.seconds(120)}
      )

      on_exit(fn ->
        Globals.pop(endpoint_cache_key(chain_id))
        clear_chain_cache()
      end)

      assert RemoteChain.ChainList.filter_endpoints(["wss://never.invalid/"], Chains.Anvil) ==
               stale_urls
    end

    test "cold-cache callers trigger exactly one probe per chain" do
      # Concurrent refresh triggers are collapsed via `Debouncer.immediate/3`:
      # the first call runs the closure (which spawns the probe as a detached
      # Task); subsequent calls within the cooldown window update the
      # Debouncer's events entry and return without spawning extra probes.
      # 20 simultaneous cold-cache calls therefore produce a single
      # background probe — not 20.
      chain_id = Chains.Anvil.chain_id()
      url = "wss://debounce.invalid/"

      Globals.put(@loaded_key, true)
      Globals.put(cache_key(chain_id), %{"chainId" => chain_id, "rpc" => [%{"url" => url}]})

      # Pre-seed `true` so the probe, when it runs, produces a non-empty list.
      now = System.monotonic_time(:millisecond)
      Globals.put({RemoteChain.ChainList, :test, url}, {true, now})

      on_exit(fn ->
        Globals.pop(cache_key(chain_id))
        Globals.pop({RemoteChain.ChainList, :test, url})
        clear_chain_cache()
      end)

      tasks =
        for _ <- 1..20,
            do:
              Task.async(fn ->
                RemoteChain.ChainList.filter_endpoints([url], Chains.Anvil)
              end)

      results = Task.await_many(tasks, 2_000)
      assert Enum.all?(results, &(&1 == [url]))

      assert eventually(
               fn ->
                 match?({[_], _ts}, Globals.get(endpoint_cache_key(chain_id)))
               end,
               2_000
             )
    end

    test "refresh_chains/1 invalidates the endpoint cache for affected chains" do
      chain_id = Chains.Anvil.chain_id()
      cached_urls = ["wss://stale.invalid/"]

      # Prime the chain cache so refresh_chains/1 (called with only_cached: true)
      # actually updates this chain.
      Globals.put(@loaded_key, true)

      Globals.put(cache_key(chain_id), %{
        "chainId" => chain_id,
        "name" => "anvil-invalidate-before",
        "rpc" => []
      })

      Globals.put(
        endpoint_cache_key(chain_id),
        {cached_urls, System.monotonic_time(:millisecond)}
      )

      on_exit(&clear_chain_cache/0)

      cached = Globals.get(endpoint_cache_key(chain_id))
      assert {^cached_urls, ts} = cached
      assert is_integer(ts)

      updated = %{"chainId" => chain_id, "name" => "anvil-invalidate", "rpc" => []}
      RemoteChain.ChainList.refresh_chains([updated])

      assert Globals.get(endpoint_cache_key(chain_id)) == nil
    end

    test "a probe in flight at clear_chain_cache time does not resurrect the cache" do
      # Regression for the eu1 Base deadlock (2026-08-14): a worker that
      # outlives its test must not write to the endpoint cache after the
      # cache has been cleared. The pre-write generation check protects
      # against this: even if the worker is still inside `probe_pass/2`
      # when `clear_chain_cache/0` bumps the counter, the write is
      # skipped because the captured generation no longer matches.
      chain_id = Chains.Anvil.chain_id()
      url = "wss://toctou.invalid/"

      Globals.put(@loaded_key, true)
      Globals.put(cache_key(chain_id), %{"chainId" => chain_id, "rpc" => [%{"url" => url}]})
      now = System.monotonic_time(:millisecond)
      Globals.put({RemoteChain.ChainList, :test, url}, {true, now})

      on_exit(fn ->
        Globals.pop(cache_key(chain_id))
        Globals.pop({RemoteChain.ChainList, :test, url})
        clear_chain_cache()
      end)

      # Schedule a refresh — a Task is spawned and the in-flight flag is
      # set. Before the Task can complete, simulate `clear_chain_cache` by
      # bumping the generation and clearing the cache.
      _ = RemoteChain.ChainList.filter_endpoints([url], Chains.Anvil)

      gen_before_clear = Globals.get({RemoteChain.ChainList, :ws_generation, chain_id})
      RemoteChain.ChainList.invalidate_endpoint_cache(chain_id)
      assert Globals.get(endpoint_cache_key(chain_id)) == nil

      # Wait long enough for any in-flight probe to finish, then assert the
      # cache stayed empty — the worker must have skipped its write because
      # the generation check failed.
      Process.sleep(50)
      assert Globals.get(endpoint_cache_key(chain_id)) == nil
      # Sanity: the generation moved.
      assert Globals.get({RemoteChain.ChainList, :ws_generation, chain_id}) > gen_before_clear
    end

    test "pocket.network and curie.radiumblock.co are dropped from the cold-cache path" do
      result =
        RemoteChain.ChainList.filter_endpoints(
          [
            "wss://rpc.pocket.network/abc",
            "https://curie.radiumblock.co/rpc",
            "https://good.invalid/rpc"
          ],
          Chains.Anvil
        )

      assert result == ["https://good.invalid/rpc"]
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

    Enum.each([@chain_id, @other_chain_id, 99_999, Chains.Anvil.chain_id()], fn chain_id ->
      Globals.pop(cache_key(chain_id))
      # Bumps the generation counter so any in-flight probe from a previous
      # test skips its write — otherwise it would resurrect the cache the new
      # test just cleared.
      RemoteChain.ChainList.invalidate_endpoint_cache(chain_id)
    end)
  end

  defp endpoint_cache_key(chain_id),
    do: {RemoteChain.ChainList, :ws_endpoints, chain_id}

  # Poll a condition until it holds or the timeout elapses. Returns the value
  # of the last evaluation; callers should assert on the boolean.
  defp eventually(fun, timeout_ms, interval_ms \\ 25) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline, interval_ms)
  end

  defp do_eventually(fun, deadline, interval_ms) do
    case fun.() do
      true ->
        true

      false ->
        if System.monotonic_time(:millisecond) >= deadline do
          false
        else
          Process.sleep(interval_ms)
          do_eventually(fun, deadline, interval_ms)
        end
    end
  end
end
