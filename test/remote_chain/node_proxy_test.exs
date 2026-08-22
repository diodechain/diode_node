# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule RemoteChain.NodeProxyTest do
  @moduledoc """
  Regression tests for Moonbeam/NodeProxy `:not_connected` handling.

  `WSConn.send_request/3` returns `{:error, :not_connected}` when the pid is
  dead or still handshaking. NodeProxy must not evict young handshakes, but
  must evict stale ones and ready sockets that fail to send.
  """
  use ExUnit.Case, async: false
  alias RemoteChain.{NodeProxy, WSConn}

  defmodule WSConnStateStub do
    use GenServer

    def start(started_at) do
      GenServer.start(__MODULE__, %WSConn{started_at: started_at})
    end

    def start_state(%WSConn{} = state), do: GenServer.start(__MODULE__, state)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_info({:"$websockex_cast", :close}, state) do
      {:stop, :normal, state}
    end

    @impl true
    def handle_info(_msg, state), do: {:noreply, state}
  end

  defp stale_started_at do
    DateTime.utc_now() |> DateTime.add(-WSConn.handshake_timeout_ms() - 1, :millisecond)
  end

  describe "pending_request_info/2" do
    test "returns method, provider url, and age for an in-flight caller" do
      caller = self()
      started = System.os_time(:millisecond) - 12_345

      state = %NodeProxy{
        chain: Chains.Anvil,
        connections: %{"wss://moonbeam.example/ws" => spawn(fn -> :timer.sleep(:infinity) end)},
        requests: %{
          1 => %{
            from: caller,
            method: "eth_call",
            ws_url: "wss://moonbeam.example/ws",
            start_ms: started
          }
        }
      }

      info = NodeProxy.pending_request_info(state, caller)

      assert info.method == "eth_call"
      assert info.ws_url == "wss://moonbeam.example/ws"
      assert info.age_ms >= 12_000
    end

    test "returns nil when caller has no in-flight request" do
      state = %NodeProxy{chain: Chains.Anvil, requests: %{}}
      assert NodeProxy.pending_request_info(state, self()) == nil
    end
  end

  describe "rpc_log_status/1" do
    test "returns :ok for successful responses" do
      assert NodeProxy.rpc_log_status(%{"id" => 1, "result" => "0x1"}) == ":ok"
    end

    test "returns :error for JSON-RPC error responses" do
      assert NodeProxy.rpc_log_status(%{
               "id" => 1,
               "error" => %{"code" => -32000, "message" => "fail"}
             }) ==
               ":error"
    end

    test "returns :error for flat error envelopes without nested error key" do
      assert NodeProxy.rpc_log_status(%{
               "id" => 8095,
               "jsonrpc" => "2.0",
               "code" => -32000,
               "message" => "VM Exception while processing transaction: revert "
             }) == ":error"
    end
  end

  describe "handle_failed_send/2" do
    test "keeps a still-handshaking (alive) WSConn in the pool" do
      # Simulate a WSConn that is doing its async handshake: the process
      # is alive but never registered itself in `Globals`, so
      # `WSConn.send_request/3` times out and returns
      # `{:error, :not_connected}`.
      conn =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      assert Process.alive?(conn)

      state = %NodeProxy{
        chain: Chains.Anvil,
        connections: %{"ws://localhost:28822" => conn},
        fallback: nil,
        fallback_url: nil,
        requests: %{}
      }

      new_state = NodeProxy.handle_failed_send(state, conn)

      # The connection MUST still be in the pool, otherwise the next
      # request will trigger `ensure_connections` to spawn yet another
      # mid-handshake WSConn, perpetuating the `:not_connected` storm.
      assert new_state.connections == state.connections,
             "alive (still handshaking) WSConn must not be evicted"

      send(conn, :stop)
    end

    test "evicts a dead WSConn and replies to its in-flight requests" do
      # Simulate a WSConn that has actually crashed.
      conn = spawn(fn -> :ok end)
      ref = Process.monitor(conn)
      assert_receive {:DOWN, ^ref, :process, ^conn, _}, 1_000
      refute Process.alive?(conn)

      from = {self(), make_ref()}

      state = %NodeProxy{
        chain: Chains.Anvil,
        connections: %{"ws://localhost:28822" => conn},
        fallback: nil,
        fallback_url: nil,
        requests: %{
          42 => %{
            from: from,
            method: "eth_blockNumber",
            params: [],
            start_ms: System.os_time(:millisecond),
            conn: conn
          }
        }
      }

      new_state = NodeProxy.handle_failed_send(state, conn)

      assert new_state.connections == %{},
             "dead WSConn must be removed from the pool"

      assert new_state.requests == %{},
             "in-flight requests on the dead WSConn must be cleared"

      # `remove_connection/2` should have replied to the orphaned caller
      # with `{:error, :disconnect}`.
      from_ref = elem(from, 1)
      assert_receive {^from_ref, {:error, :disconnect}}, 1_000
    end

    test "evicts a ready WSConn after send failure (stale socket)" do
      conn =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      Globals.put({WSConn, conn}, :fake_conn)

      try do
        assert WSConn.ready?(conn)

        state = %NodeProxy{
          chain: Chains.Anvil,
          connections: %{"ws://localhost:28822" => conn},
          fallback: nil,
          fallback_url: nil,
          requests: %{}
        }

        new_state = NodeProxy.handle_failed_send(state, conn)
        assert new_state.connections == %{}
      after
        Globals.pop({WSConn, conn})
        send(conn, :stop)
      end
    end

    test "evicts a handshake-stale WSConn" do
      {:ok, conn} = WSConnStateStub.start(stale_started_at())

      assert WSConn.handshake_stale?(conn)

      state = %NodeProxy{
        chain: Chains.Anvil,
        connections: %{"ws://localhost:28822" => conn},
        fallback: nil,
        fallback_url: nil,
        requests: %{}
      }

      new_state = NodeProxy.handle_failed_send(state, conn)
      assert new_state.connections == %{}
    end

    test "evicts a dead fallback WSConn and resets fallback_url" do
      conn = spawn(fn -> :ok end)
      ref = Process.monitor(conn)
      assert_receive {:DOWN, ^ref, :process, ^conn, _}, 1_000
      refute Process.alive?(conn)

      state = %NodeProxy{
        chain: Chains.Anvil,
        connections: %{},
        fallback: conn,
        fallback_url: "ws://fallback.example/",
        requests: %{}
      }

      new_state = NodeProxy.handle_failed_send(state, conn)

      assert new_state.fallback == nil
      assert new_state.fallback_url == nil
    end
  end

  describe "pick_connection/1" do
    test "prefers ready WSConns over still-handshaking ones" do
      ready_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      handshaking_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      # Mark `ready_pid` as ready by mimicking what `WSConn.handle_connect/2`
      # does: publish the underlying connection in `Globals` under
      # `{WSConn, pid}`. The actual value is opaque to the readiness check.
      Globals.put({RemoteChain.WSConn, ready_pid}, :fake_conn)

      try do
        assert RemoteChain.WSConn.ready?(ready_pid)
        refute RemoteChain.WSConn.ready?(handshaking_pid)

        proxy = %NodeProxy{
          connections: %{
            "ws://ready/" => ready_pid,
            "ws://handshaking/" => handshaking_pid
          },
          fallback: nil
        }

        for _ <- 1..200 do
          assert {:ok, ^ready_pid} = NodeProxy.pick_connection(proxy),
                 "must never route to a still-handshaking WSConn while a ready one is available"
        end
      after
        Globals.pop({RemoteChain.WSConn, ready_pid})
        send(ready_pid, :stop)
        send(handshaking_pid, :stop)
      end
    end

    test "returns no_ready when every primary handshake is stale" do
      {:ok, pid_a} = WSConnStateStub.start(stale_started_at())
      {:ok, pid_b} = WSConnStateStub.start(stale_started_at())

      proxy = %NodeProxy{
        connections: %{"ws://a/" => pid_a, "ws://b/" => pid_b},
        fallback: nil
      }

      for _ <- 1..20 do
        assert {:error, :no_ready_connection} = NodeProxy.pick_connection(proxy)
      end
    end

    test "still routes to a young handshaking primary when nothing is ready yet" do
      pid_a = spawn(fn -> receive do: (:stop -> :ok) end)
      pid_b = spawn(fn -> receive do: (:stop -> :ok) end)

      try do
        proxy = %NodeProxy{
          connections: %{"ws://a/" => pid_a, "ws://b/" => pid_b},
          fallback: nil
        }

        seen =
          for _ <- 1..50, into: MapSet.new() do
            {:ok, pid} = NodeProxy.pick_connection(proxy)
            pid
          end

        assert MapSet.subset?(seen, MapSet.new([pid_a, pid_b]))
      after
        send(pid_a, :stop)
        send(pid_b, :stop)
      end
    end

    test "uses ready fallback when primaries are still handshaking" do
      handshaking = spawn(fn -> receive do: (:stop -> :ok) end)

      ready_fallback =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      Globals.put({WSConn, ready_fallback}, :fake_conn)

      try do
        proxy = %NodeProxy{
          connections: %{"ws://primary/" => handshaking},
          fallback: ready_fallback
        }

        assert {:ok, ^ready_fallback} = NodeProxy.pick_connection(proxy)
      after
        Globals.pop({WSConn, ready_fallback})
        send(handshaking, :stop)
        send(ready_fallback, :stop)
      end
    end
  end

  describe "WSConn.handshake_stale?/1" do
    test "is false for a young handshaking pid" do
      {:ok, pid} = WSConnStateStub.start(DateTime.utc_now())
      refute WSConn.handshake_stale?(pid)
    end

    test "is true after handshake_timeout_ms" do
      {:ok, pid} = WSConnStateStub.start(stale_started_at())
      assert WSConn.handshake_stale?(pid)
    end
  end

  describe "WSConn.ready?/1" do
    test "returns false for an alive but non-registered (still handshaking) pid" do
      pid = spawn(fn -> receive do: (:stop -> :ok) end)

      try do
        refute RemoteChain.WSConn.ready?(pid),
               "a WSConn that has not run handle_connect/2 yet must not be reported ready"

        # Crucially, calling `ready?/1` must NOT register a waiter in
        # `Globals` -- otherwise the caller would either block or leave
        # a zombie waiting entry that later fires
        # `Logger.error("Timeout waiting for {RemoteChain.WSConn, ...}")`.
        # We verify that by asserting the pid is still not "ready" and
        # that no `:update` message landed in our mailbox from the call.
        refute_receive {:update, {RemoteChain.WSConn, ^pid}, _}, 50
      after
        send(pid, :stop)
      end
    end

    test "returns true once handle_connect/2 has registered the conn" do
      pid = spawn(fn -> receive do: (:stop -> :ok) end)
      Globals.put({RemoteChain.WSConn, pid}, :fake_conn)

      try do
        assert RemoteChain.WSConn.ready?(pid)
      after
        Globals.pop({RemoteChain.WSConn, pid})
        send(pid, :stop)
      end
    end
  end

  describe "rate_limited_disconnect?/1" do
    test "detects WebSockex 429 request errors" do
      assert NodeProxy.rate_limited_disconnect?(
               {:error, %WebSockex.RequestError{code: 429, message: "Too Many Requests"}}
             )

      assert NodeProxy.rate_limited_disconnect?(%WebSockex.RequestError{
               code: 429,
               message: "Too Many Requests"
             })

      refute NodeProxy.rate_limited_disconnect?(:normal)
      refute NodeProxy.rate_limited_disconnect?({:error, :closed})
    end
  end

  describe "handle_info({:new_block, ...}) consensus" do
    # Regression for the us1/Oasis incident: a fallback WSConn silently
    # stopped pushing newHeads frames while staying connected. The primary
    # provider kept advancing, but `NodeProxy` published the stale fallback
    # block forever because the consensus required 2/2 votes.
    @primary_url "wss://primary.example/ws"
    @fallback_url "wss://fallback.example/oasis/mainnet/"

    defp fresh_date, do: DateTime.utc_now()

    defp alive_noop_pid do
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)
    end

    defp build_state(primary_lastblocks, fallback) do
      %NodeProxy{
        chain: Chains.OasisSapphire,
        connections: %{@primary_url => alive_noop_pid()},
        fallback: fallback,
        fallback_url: if(fallback, do: @fallback_url, else: nil),
        lastblocks: primary_lastblocks,
        lastblock: 0
      }
    end

    defp stub_fallback(lastblock_at) do
      {:ok, pid} =
        WSConnStateStub.start_state(%WSConn{started_at: lastblock_at, lastblock_at: lastblock_at})

      pid
    end

    defp apply_new_block(state, url, block) do
      {:noreply, new_state} = NodeProxy.handle_info({:new_block, url, block}, state)
      new_state
    end

    test "ignores a frozen fallback when the primary advances (the us1/Oasis bug)" do
      fallback = stub_fallback(DateTime.add(fresh_date(), -30 * 60, :second))
      state = build_state(%{}, fallback)

      state = apply_new_block(state, @primary_url, 20)

      # Without the fix, published block stays at 0 because the frozen
      # fallback only has block 10 and security_level is 2. With the fix,
      # the frozen fallback is excluded from the quorum and the primary
      # alone advances the published block.
      assert state.lastblock == 20
    end

    test "advances when both providers are live and reporting recent blocks" do
      fallback = stub_fallback(fresh_date())
      state = build_state(%{}, fallback)

      state = apply_new_block(state, @primary_url, 10)
      # Only the primary has reached 10. With security_level = 2 (fallback
      # configured), the published block stays at 0.
      assert state.lastblock == 0

      state = apply_new_block(state, @fallback_url, 10)
      # Both providers agree at 10; the published block advances.
      assert state.lastblock == 10
    end

    test "re-admits a previously-frozen fallback once it posts a fresh block" do
      stale_ts = DateTime.add(fresh_date(), -30 * 60, :second)

      # Both the WSConn's `lastblock_at` and the cached `lastblocks` entry
      # are stale. The fallback is treated as not present for the consensus.
      fallback = stub_fallback(stale_ts)

      state =
        build_state(
          %{@fallback_url => {10, stale_ts}},
          fallback
        )

      # Primary alone advances to 22 (fallback is stale, security_level = 1).
      state = apply_new_block(state, @primary_url, 22)
      assert state.lastblock == 22

      # Fallback recovers with a fresh block at 22. With security_level = 2
      # the consensus now needs two providers at 22, so the published block
      # advances to 22.
      state = apply_new_block(state, @fallback_url, 22)
      assert state.lastblock == 22
    end

    test "degrades to security_level=1 when no fallback is configured" do
      state = build_state(%{}, nil)

      state = apply_new_block(state, @primary_url, 5)
      assert state.lastblock == 5
    end

    test "degrades to security_level=1 when the configured fallback is stale" do
      fallback = stub_fallback(DateTime.add(fresh_date(), -30 * 60, :second))
      state = build_state(%{}, fallback)

      # Even though `fallback != nil`, the staleness check should drop
      # security_level back to 1 so the primary advances.
      state = apply_new_block(state, @primary_url, 5)
      assert state.lastblock == 5
    end

    test "ignores newHeads from a stale provider when computing the quorum" do
      # Both providers have stale entries in lastblocks (the test simulates
      # a scenario where a provider was previously healthy but now silent).
      stale_ts = DateTime.add(fresh_date(), -30 * 60, :second)
      fallback = stub_fallback(stale_ts)

      state =
        build_state(
          %{
            @primary_url => {5, stale_ts},
            @fallback_url => {5, stale_ts}
          },
          fallback
        )

      state = apply_new_block(state, @primary_url, 6)

      # The primary's new block has a fresh `lastblock_at`, but the
      # fallback's entry is stale. Stale entries contribute zero votes, so
      # the primary's single live vote satisfies the (now-degraded)
      # security_level = 1.
      assert state.lastblock == 6
    end
  end

  describe "prune_stale_connections/1 eviction" do
    @fallback_url "wss://fallback.example/oasis/mainnet/"

    test "evicts a fallback that has not produced a block for >20 block intervals" do
      # 30 minutes = 1800s on a 6s cadence = 300 intervals, well past the
      # 20-interval (120s) eviction cutoff for Oasis.
      very_stale = DateTime.add(DateTime.utc_now(), -1800, :second)

      state =
        build_min_state()
        |> with_fallback(very_stale)
        |> Map.put(:lastblocks, %{@fallback_url => {10, very_stale}})

      new_state = NodeProxy.prune_stale_connections(state)

      assert new_state.fallback == nil
      assert new_state.fallback_url == nil
    end

    test "keeps a fallback that has produced a block within the last 20 intervals" do
      # 30s on Oasis (6s cadence) = 5 intervals, well below the 20-interval
      # eviction cutoff.
      fresh = DateTime.add(DateTime.utc_now(), -30, :second)
      state = with_fallback(build_min_state(), fresh)
      state = %{state | lastblocks: %{@fallback_url => {10, fresh}}}

      new_state = NodeProxy.prune_stale_connections(state)

      assert new_state.fallback == state.fallback
      assert new_state.fallback_url == @fallback_url
    end

    test "evicts a never-blocked connection whose WSConn has gone stale" do
      # Regression: a WSConn that finished its handshake but never received
      # a newHeads frame (no entry in `lastblocks`) used to skip the
      # eviction contract entirely. The fix uses the WSConn's own
      # `lastblock_at` (initialised at start) as a fallback.
      very_stale = DateTime.add(DateTime.utc_now(), -1800, :second)
      state = with_fallback(build_min_state(), very_stale)

      new_state = NodeProxy.prune_stale_connections(state)

      assert new_state.fallback == nil
      assert new_state.fallback_url == nil
    end
  end

  describe "prune_unresponsive_connections/1 watchdog" do
    test "watchdog_timeout_ms is 5x the caller timeout (25s)" do
      assert NodeProxy.watchdog_timeout_ms() == 5 * 25_000
    end

    test "evicts a connection whose request went unanswered past the watchdog timeout" do
      # Zombie-provider regression (sapphire.oasis.io incident): the WS
      # connection stayed alive and kept streaming newHeads, but never
      # answered any RPC. Without the watchdog NodeProxy kept routing
      # requests to it for minutes and every caller died on the 25s
      # GenServer.call timeout.
      conn = spawn(fn -> receive do: (:stop -> :ok) end)
      from = {self(), make_ref()}
      overdue_ms = System.os_time(:millisecond) - NodeProxy.watchdog_timeout_ms() - 1_000

      state = %NodeProxy{
        chain: Chains.OasisSapphire,
        connections: %{"wss://sapphire.example/ws" => conn},
        fallback: nil,
        fallback_url: nil,
        requests: %{
          409 => %{
            from: from,
            method: "eth_getBlockByNumber",
            params: ["0xeacb9d", false],
            start_ms: overdue_ms,
            conn: conn,
            ws_url: "wss://sapphire.example/ws"
          }
        }
      }

      new_state = NodeProxy.prune_unresponsive_connections(state)

      assert new_state.connections == %{}, "zombie WSConn must be evicted"
      assert new_state.requests == %{}, "dead requests on the evicted WSConn must be cleared"

      # The orphaned caller gets a disconnect reply (harmless if it has
      # already timed out) instead of the entry leaking forever.
      from_ref = elem(from, 1)
      assert_receive {^from_ref, {:error, :disconnect}}, 1_000
    end

    test "keeps connections whose requests are still within the watchdog timeout" do
      conn = spawn(fn -> receive do: (:stop -> :ok) end)

      state = %NodeProxy{
        chain: Chains.OasisSapphire,
        connections: %{"wss://sapphire.example/ws" => conn},
        fallback: nil,
        fallback_url: nil,
        requests: %{
          410 => %{
            from: {self(), make_ref()},
            method: "eth_getBlockByNumber",
            params: ["0xeacb9e", false],
            start_ms: System.os_time(:millisecond),
            conn: conn,
            ws_url: "wss://sapphire.example/ws"
          }
        }
      }

      new_state = NodeProxy.prune_unresponsive_connections(state)

      assert new_state.connections == state.connections
      assert new_state.requests == state.requests

      send(conn, :stop)
    end

    test "evicts an unresponsive fallback connection too" do
      conn = spawn(fn -> receive do: (:stop -> :ok) end)
      overdue_ms = System.os_time(:millisecond) - NodeProxy.watchdog_timeout_ms() - 1_000

      state = %NodeProxy{
        chain: Chains.OasisSapphire,
        connections: %{},
        fallback: conn,
        fallback_url: "wss://fallback.example/oasis/mainnet/",
        requests: %{
          411 => %{
            from: {self(), make_ref()},
            method: "eth_getBlockByNumber",
            params: ["0xeacb9f", false],
            start_ms: overdue_ms,
            conn: conn,
            ws_url: "wss://fallback.example/oasis/mainnet/"
          }
        }
      }

      new_state = NodeProxy.prune_unresponsive_connections(state)

      assert new_state.fallback == nil
      assert new_state.fallback_url == nil
      assert new_state.requests == %{}
    end

    test "handle_info(:watchdog) prunes and re-arms itself" do
      prev = :persistent_term.get({NodeProxy, :watchdog_interval_ms}, nil)

      try do
        NodeProxy.set_watchdog_interval_ms(10)

        conn = spawn(fn -> receive do: (:stop -> :ok) end)
        overdue_ms = System.os_time(:millisecond) - NodeProxy.watchdog_timeout_ms() - 1_000

        state = %NodeProxy{
          chain: Chains.OasisSapphire,
          connections: %{"wss://sapphire.example/ws" => conn},
          fallback: nil,
          fallback_url: nil,
          requests: %{
            412 => %{
              from: {self(), make_ref()},
              method: "eth_getBlockByNumber",
              params: ["0xeacba0", false],
              start_ms: overdue_ms,
              conn: conn,
              ws_url: "wss://sapphire.example/ws"
            }
          }
        }

        assert {:noreply, new_state} = NodeProxy.handle_info(:watchdog, state)
        assert new_state.connections == %{}

        # The watchdog must re-arm itself, otherwise a single run would
        # silently disable the protection permanently.
        assert_receive :watchdog, 1_000
      after
        if prev, do: :persistent_term.put({NodeProxy, :watchdog_interval_ms}, prev)
      end
    end
  end

  # Shared helpers for the `prune_stale_connections/1` eviction tests.
  # Mark the stub as ready (so the handshake-stale check is not the one
  # evicting) and use a started_at that is within the handshake timeout.
  # Only the data-staleness check should apply.
  defp with_fallback(state, lastblock_at) do
    started_at = DateTime.utc_now()
    {:ok, fallback} = WSConnStateStub.start_state(%WSConn{started_at: started_at})
    Globals.put({WSConn, fallback}, :fake_conn)

    :sys.replace_state(fallback, fn %WSConn{} = wsconn ->
      %{wsconn | lastblock_at: lastblock_at}
    end)

    %{state | fallback: fallback, fallback_url: "wss://fallback.example/oasis/mainnet/"}
  end

  defp build_min_state do
    %NodeProxy{
      chain: Chains.OasisSapphire,
      connections: %{},
      fallback: nil,
      fallback_url: nil,
      lastblocks: %{}
    }
  end

  describe "ensure_connections/1 fallback URL" do
    @ws_env_key "CHAINS_ANVIL_WS"
    @fb_env_key "CHAINS_ANVIL_WS_FALLBACK"

    setup do
      prev_ws = System.get_env(@ws_env_key)
      prev_fb = System.get_env(@fb_env_key)

      on_exit(fn ->
        if prev_ws,
          do: System.put_env(@ws_env_key, prev_ws),
          else: System.delete_env(@ws_env_key)

        if prev_fb,
          do: System.put_env(@fb_env_key, prev_fb),
          else: System.delete_env(@fb_env_key)
      end)

      :ok
    end

    test "does not create a fallback from regular ws_endpoints when CHAINS_*_WS_FALLBACK is unset" do
      # Regression for the eu1 Base deadlock (2026-08-10): NodeProxy was
      # silently falling back to `new_urls` when no CHAINS_BASE_WS_FALLBACK
      # was set, raising security_level to 2 with only one unique URL ever
      # available. The result was `live_voter_count = 1 >= security_level = 2`
      # being false forever, so `RPCCache.block_number/1` stayed at nil and
      # every EdgeV2 device timed out.
      System.put_env(@ws_env_key, "ws://a.example/ ws://b.example/")
      System.delete_env(@fb_env_key)

      pid = alive_noop_pid()

      state = %NodeProxy{
        chain: Chains.Anvil,
        connections: %{"ws://a.example/" => pid},
        fallback: nil,
        fallback_url: nil
      }

      new_state = NodeProxy.ensure_connections(state)

      # With the fix: fallback_url stays nil, no fallback is spawned, and
      # security_level stays at 1 so the single live voter is enough to
      # advance the published block.
      assert new_state.fallback == nil
      assert new_state.fallback_url == nil

      send(pid, :stop)
    end

    test "creates a fallback from CHAINS_*_WS_FALLBACK when configured" do
      System.put_env(@ws_env_key, "ws://a.example/ ws://b.example/")
      System.put_env(@fb_env_key, "ws://fallback.example/")

      pid = alive_noop_pid()

      state = %NodeProxy{
        chain: Chains.Anvil,
        connections: %{"ws://a.example/" => pid},
        fallback: nil,
        fallback_url: nil
      }

      new_state = NodeProxy.ensure_connections(state)

      # The fallback URL must come from the explicit CHAINS_*_WS_FALLBACK
      # list, never from the regular ws_endpoints pool. The pid slot is
      # populated regardless of whether the WebSocket itself can connect;
      # production behaviour is unchanged from before the fix.
      assert new_state.fallback_url == "ws://fallback.example/"
      assert is_pid(new_state.fallback)

      send(pid, :stop)

      if is_pid(new_state.fallback) and Process.alive?(new_state.fallback),
        do: RemoteChain.WSConn.close(new_state.fallback)
    end

    test "handles a multi-URL CHAINS_*_WS_FALLBACK by picking one at random" do
      System.put_env(@ws_env_key, "ws://a.example/ ws://b.example/")

      fb_urls = ["ws://fb1.example/", "ws://fb2.example/", "ws://fb3.example/"]
      System.put_env(@fb_env_key, Enum.join(fb_urls, " "))

      pid = alive_noop_pid()

      state = %NodeProxy{
        chain: Chains.Anvil,
        connections: %{"ws://a.example/" => pid},
        fallback: nil,
        fallback_url: nil
      }

      new_state = NodeProxy.ensure_connections(state)

      assert new_state.fallback_url in fb_urls
      assert is_pid(new_state.fallback)

      send(pid, :stop)

      if is_pid(new_state.fallback) and Process.alive?(new_state.fallback),
        do: RemoteChain.WSConn.close(new_state.fallback)
    end
  end
end
