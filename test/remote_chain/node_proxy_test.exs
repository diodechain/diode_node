# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule RemoteChain.NodeProxyTest do
  @moduledoc """
  Regression tests for the `:not_connected` retry storm described in
  `lib/remote_chain/node_proxy.ex`.

  Background:

  When `RemoteChain.WSConn.send_request/3` fails to deliver the frame it
  returns `{:error, :not_connected}`. This can happen for two distinct
  reasons:

    1. The WSConn process is dead (crashed, exited before `handle_connect`
       fired, etc.).
    2. The WSConn process is still alive but its async handshake (TCP +
       TLS + WebSocket upgrade) has not completed within the 500 ms
       `Globals.await` budget yet.

  Until this fix `RemoteChain.NodeProxy.send_request/6` always treated
  every failed send as case (1) and evicted the connection, then asked
  `ensure_connections` to spawn a fresh WSConn. Under case (2) that fresh
  WSConn is *also* mid-handshake, so the next request hits the same
  `:not_connected` -> evict -> respawn loop and the warning

      Failed to send request to #PID<...>: ... {:error, :not_connected}

  followed by

      ** (RuntimeError) RPC error in ChainImpl.eth_getBlockByNumber(...): {:error, :disconnect}

  keeps repeating instead of healing once the in-flight handshake
  finishes.
  """
  use ExUnit.Case, async: false
  alias RemoteChain.NodeProxy

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

  # Second symptom of the same root cause:
  #
  #     00:15:45.880 [warning] Failed to send request to #PID<0.109448870.0>: ... {:error, :not_connected}
  #     00:15:45.881 [info] Awaiting undefined key: {RemoteChain.WSConn, #PID<0.109449407.0>}
  #     ** (RuntimeError) RPC error in Chains.Moonbeam.eth_getBlockByNumber(...): {:error, :disconnect}
  #
  # Two distinct WSConn pids in two consecutive log lines: one had
  # `send_request/3` time out, then `RPCCache`'s retry picked a *second*
  # still-handshaking WSConn from the pool and timed out again.
  #
  # `NodeProxy.handle_call({:rpc, ...})` used to pick blindly with
  # `Enum.random(Map.values(state.connections))`, so when several
  # WSConns were handshaking simultaneously every random pick paid the
  # full 500 ms `Globals.await` budget and failed. The fix is
  # `pick_connection/1`, which prefers WSConns whose handshake has
  # already completed (`WSConn.ready?/1`).
  describe "pick_connection/1 (regression: avoid still-handshaking conns)" do
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

        connections = %{
          "ws://ready/" => ready_pid,
          "ws://handshaking/" => handshaking_pid
        }

        # Run many picks. Without the fix this is uniform random over
        # the two pids, so on a 2-conn pool the handshaking pid would be
        # chosen ~50% of the time. With the fix it must be picked 0% of
        # the time as long as a ready peer exists.
        for _ <- 1..200 do
          assert NodeProxy.pick_connection(connections) == ready_pid,
                 "must never route to a still-handshaking WSConn while a ready one is available"
        end
      after
        Globals.pop({RemoteChain.WSConn, ready_pid})
        send(ready_pid, :stop)
        send(handshaking_pid, :stop)
      end
    end

    test "falls back to the full pool when no WSConn is ready yet" do
      # Right after start-up (or after both conns were just respawned)
      # every pid in the pool is handshaking. We must still attempt the
      # request -- not crash on an empty list -- so callers get a
      # well-defined `{:error, :disconnect}` rather than a process exit.
      pid_a = spawn(fn -> receive do: (:stop -> :ok) end)
      pid_b = spawn(fn -> receive do: (:stop -> :ok) end)

      try do
        refute RemoteChain.WSConn.ready?(pid_a)
        refute RemoteChain.WSConn.ready?(pid_b)

        connections = %{"ws://a/" => pid_a, "ws://b/" => pid_b}

        seen =
          for _ <- 1..200, into: MapSet.new() do
            NodeProxy.pick_connection(connections)
          end

        assert MapSet.subset?(seen, MapSet.new([pid_a, pid_b]))
        assert MapSet.size(seen) >= 1
      after
        send(pid_a, :stop)
        send(pid_b, :stop)
      end
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
end
