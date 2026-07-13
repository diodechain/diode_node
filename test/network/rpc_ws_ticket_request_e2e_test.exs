# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.RpcWsTicketRequestE2eTest do
  use ExUnit.Case, async: false
  import TestHelper
  alias DiodeClient.Wallet

  @device_wallet RpcClient.clientid(1)
  @device Wallet.address!(@device_wallet)

  setup do
    reset()

    Application.put_env(:diode, :rpc_ws_ticket_usage_bytes, 1000)
    Application.put_env(:diode, :rpc_ws_ticket_interval_ms, 100_000)
    Application.put_env(:diode, :rpc_ws_ticket_deadline_ms, 100_000)

    on_exit(fn ->
      Application.delete_env(:diode, :rpc_ws_ticket_usage_bytes)
      Application.delete_env(:diode, :rpc_ws_ticket_interval_ms)
      Application.delete_env(:diode, :rpc_ws_ticket_deadline_ms)
    end)

    :ok
  end

  test "websocket receives dio_ticket_request after usage threshold" do
    pid = RpcClient.connect()
    assert :ok = RpcClient.authenticate(pid, 1)

    TicketStore.increase_device_usage(@device, 1500)

    # Usage publish is debounced in TicketStore; deliver directly to the websocket like PubSub.
    PubSub.publish({:edge, @device}, {:device_usage, @device})

    assert_receive {:notification, %{"method" => "dio_ticket_request", "params" => params}}, 5000
    assert is_integer(params["usage"])
    assert params["fleet"] =~ "0x"

    RpcClient.disconnect(pid)
  end
end
