# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.RpcWsTicketBillingTest do
  use ExUnit.Case, async: false
  import TestHelper
  alias DiodeClient.Wallet
  alias Network.{RpcWsTicketBilling, TicketRequestPolicy}

  @device_wallet RpcClient.clientid(1)
  @device Wallet.address!(@device_wallet)
  @fleet RemoteChain.developer_fleet_address(Chains.Anvil)

  defp follow_up_ticket_hex do
    usage = TicketStore.device_usage(@device)

    Edge2Client.encode_ticket_for_dio_ticket(1,
      total_bytes: usage + TicketRequestPolicy.ws_usage_bytes()
    )
  end

  setup do
    reset()
    Network.RpcWsTicketBilling.deactivate()

    on_exit(fn ->
      Application.delete_env(:diode, :rpc_ws_ticket_usage_bytes)
      Application.delete_env(:diode, :rpc_ws_ticket_interval_ms)
      Application.delete_env(:diode, :rpc_ws_ticket_deadline_ms)
      Network.RpcWsTicketBilling.deactivate()
    end)

    :ok
  end

  describe "TicketRequestPolicy" do
    test "documents distinct websocket and edge thresholds" do
      summary = TicketRequestPolicy.summary()

      assert summary.websocket.usage_bytes == 10_000_000
      assert summary.websocket.interval_ms == :timer.minutes(5)
      assert summary.websocket.deadline_ms == 20_000

      assert summary.edge_v2.min_protocol_version == 1001
      assert summary.edge_v2.refresh_interval_ms == :timer.hours(8)
      assert summary.edge_v2.deadline_ms == 20_000

      assert summary.edge_v2.send_threshold_bytes ==
               TicketRequestPolicy.edge_send_threshold_bytes()
    end
  end

  describe "TicketRequestPolicy.ws_should_request?/3" do
    test "bytes threshold (default 10 MiB)" do
      markers = %{usage_at_last_request: 100, last_request_at: 0}

      refute TicketRequestPolicy.ws_should_request?(
               markers,
               1000,
               100 + 10_000_000 - 1
             )

      assert TicketRequestPolicy.ws_should_request?(markers, 1000, 100 + 10_000_000)
    end

    test "time threshold (default 5 minutes)" do
      markers = %{usage_at_last_request: 0, last_request_at: 0}

      refute TicketRequestPolicy.ws_should_request?(markers, :timer.minutes(5) - 1, 0)
      assert TicketRequestPolicy.ws_should_request?(markers, :timer.minutes(5), 0)
    end
  end

  describe "connection process billing" do
    setup do
      Application.put_env(:diode, :rpc_ws_ticket_usage_bytes, 1000)
      Application.put_env(:diode, :rpc_ws_ticket_interval_ms, 100_000)
      Application.put_env(:diode, :rpc_ws_ticket_deadline_ms, 50)
      :ok
    end

    test "dio_ticket_request notification on usage threshold" do
      assert :ok = RpcWsTicketBilling.on_ticket_accepted(@device, @fleet)

      TicketStore.increase_device_usage(@device, 1500)
      assert :ok = RpcWsTicketBilling.on_device_usage(@device)

      assert_receive {:rpc_ws_push_notification, notification}, 500

      assert notification["method"] == "dio_ticket_request"
      assert is_integer(notification["params"]["usage"])
      assert notification["params"]["fleet"] =~ "0x"
    end

    test "second notification waits for next threshold after ack" do
      assert :ok = RpcWsTicketBilling.on_ticket_accepted(@device, @fleet)

      TicketStore.increase_device_usage(@device, 1500)
      assert :ok = RpcWsTicketBilling.on_device_usage(@device)
      assert_receive {:rpc_ws_push_notification, _}, 500

      assert {nil, 200, _} =
               Network.Rpc.execute_dio("dio_ticket", [follow_up_ticket_hex()], %{
                 connection_state: true
               })

      TicketStore.increase_device_usage(@device, 500)
      refute_receive {:rpc_ws_push_notification, _}, 50

      TicketStore.increase_device_usage(@device, 600)
      assert :ok = RpcWsTicketBilling.on_device_usage(@device)
      assert_receive {:rpc_ws_push_notification, _}, 500
    end

    test "deadline closes connection when no new ticket" do
      assert :ok = RpcWsTicketBilling.on_ticket_accepted(@device, @fleet)
      TicketStore.increase_device_usage(@device, 2000)
      assert :ok = RpcWsTicketBilling.on_device_usage(@device)

      assert_receive {:rpc_ws_push_notification, _}, 500
      assert_receive {:rpc_ws_ticket_deadline, required_version}, 500

      Process.sleep(60)
      assert :close = RpcWsTicketBilling.on_deadline(required_version)
    end

    test "successful dio_ticket cancels deadline" do
      assert :ok = RpcWsTicketBilling.on_ticket_accepted(@device, @fleet)
      TicketStore.increase_device_usage(@device, 2000)
      assert :ok = RpcWsTicketBilling.on_device_usage(@device)

      assert_receive {:rpc_ws_push_notification, _}, 500
      assert_receive {:rpc_ws_ticket_deadline, required_version}, 500

      assert {nil, 200, _} =
               Network.Rpc.execute_dio("dio_ticket", [follow_up_ticket_hex()], %{
                 connection_state: true
               })

      Process.sleep(60)
      assert :ok = RpcWsTicketBilling.on_deadline(required_version)
      refute_receive :rpc_ws_close_ticket_deadline, 50
    end

    test "interval timer sends notification" do
      Application.put_env(:diode, :rpc_ws_ticket_interval_ms, 50)
      assert :ok = RpcWsTicketBilling.on_ticket_accepted(@device, @fleet)

      refute_receive {:rpc_ws_push_notification, _}, 30
      assert_receive :rpc_ws_ticket_interval, 200
      assert :ok = RpcWsTicketBilling.on_interval()
      assert_receive {:rpc_ws_push_notification, _}, 500
    end
  end
end
