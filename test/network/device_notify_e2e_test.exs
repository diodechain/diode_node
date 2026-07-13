# Diode Server
# Copyright 2021-2025 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.DeviceNotifyE2eTest do
  use ExUnit.Case, async: false
  import TestHelper
  alias DiodeClient.Wallet

  @device_wallet RpcClient.clientid(1)
  @device Wallet.address!(@device_wallet)

  setup do
    reset()
    :ok
  end

  test "websocket receives dio_notify on authenticated session" do
    pid = RpcClient.connect()
    assert :ok = RpcClient.authenticate(pid, 1)

    PubSub.publish(
      {:edge, @device},
      {:device_notify, "warning", "fleet_not_found", "Fleet is not registered on this chain"}
    )

    assert_receive {:notification, %{"method" => "dio_notify", "params" => params}}, 5000

    assert params == %{
             "level" => "warning",
             "code" => "fleet_not_found",
             "message" => "Fleet is not registered on this chain"
           }

    RpcClient.disconnect(pid)
  end
end
