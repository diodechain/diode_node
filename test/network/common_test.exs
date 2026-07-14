# Diode Server
# Copyright 2021-2025 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.CommonTest do
  use ExUnit.Case, async: true

  alias DiodeClient.Wallet
  alias Network.Common

  test "handle_client_exit_noreply works when state has no ready map" do
    peer = Wallet.new()
    key = Wallet.address!(peer)

    handler =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Network.EdgeServer{
      clients: %{
        handler => key,
        key => Common.client_entry(handler, {127, 0, 0, 1}, 12_345)
      }
    }

    assert {:noreply, updated} =
             Common.handle_client_exit_noreply(state, handler, :function_clause, "Network.EdgeV2")

    refute Map.has_key?(updated, :ready)
    refute Map.has_key?(updated.clients, handler)
    refute Map.has_key?(updated.clients, key)
  end

  test "handle_client_exit_noreply updates ready map when present" do
    peer = Wallet.new()
    key = Wallet.address!(peer)

    handler =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Network.PeerServer{
      clients: %{
        handler => key,
        key => Common.client_entry(handler, {127, 0, 0, 1}, 12_345)
      },
      ready: %{key => handler}
    }

    Network.PeerReadyEts.reset()
    Network.PeerReadyEts.insert(key, handler)

    assert {:noreply, updated} =
             Common.handle_client_exit_noreply(
               state,
               handler,
               :function_clause,
               "Network.PeerHandlerV2"
             )

    assert updated.ready == %{}
    assert Network.PeerReadyEts.read() == %{}
    refute Map.has_key?(updated.clients, handler)
    refute Map.has_key?(updated.clients, key)
  end

  test "PeerReadyEts.read returns empty map when table is missing" do
    Network.PeerReadyEts.reset()
    :ets.delete(:peer_ready_connections)
    assert Network.PeerReadyEts.read() == %{}
    Network.PeerReadyEts.ensure()
    assert :ets.info(:peer_ready_connections) != :undefined
  end
end
