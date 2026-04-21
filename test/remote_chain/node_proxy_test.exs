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
end
