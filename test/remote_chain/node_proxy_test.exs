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
      GenServer.start(__MODULE__, started_at)
    end

    @impl true
    def init(started_at), do: {:ok, %WSConn{started_at: started_at}}
  end

  defp stale_started_at do
    DateTime.utc_now() |> DateTime.add(-WSConn.handshake_timeout_ms() - 1, :millisecond)
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
end
