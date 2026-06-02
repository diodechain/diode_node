# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.RpcWsTooLowTest do
  use ExUnit.Case, async: false
  import TestHelper
  alias DiodeClient.Object.TicketV2, as: Ticket
  alias DiodeClient.{Base16, Rlp, Rlpx, Wallet}
  import Ticket, only: [ticketv2: 1]

  @chain Chains.Anvil

  setup do
    reset()
    :ok
  end

  test "websocket dio_ticket too_low returns non-zero usage in error data" do
    wallet = RpcClient.clientid(1)
    device = Wallet.address!(wallet)
    epoch = RemoteChain.epoch(@chain) - 1
    fleet = RemoteChain.developer_fleet_address(@chain)
    key = Wallet.privkey!(wallet)

    high =
      ticketv2(
        chain_id: @chain.chain_id(),
        server_id: Wallet.address!(Diode.wallet()),
        total_connections: 10,
        total_bytes: 1_000_000,
        local_address: "rpc_ws_too_low_test",
        epoch: epoch,
        fleet_contract: fleet
      )
      |> Ticket.device_sign(key)

    assert {:ok, _} = Network.TicketSubmission.submit(high, wallet)

    TicketStore.increase_device_usage(device, 500_000)

    better_score =
      ticketv2(
        chain_id: @chain.chain_id(),
        server_id: Wallet.address!(Diode.wallet()),
        total_connections: 5_000,
        total_bytes: 50_000,
        local_address: "rpc_ws_too_low_test",
        epoch: epoch,
        fleet_contract: fleet
      )
      |> Ticket.device_sign(key)

    hex =
      [
        "ticketv2",
        Rlpx.uint2bin(Ticket.chain_id(better_score)),
        Rlpx.uint2bin(Ticket.epoch(better_score)),
        Ticket.fleet_contract(better_score),
        Rlpx.uint2bin(Ticket.total_connections(better_score)),
        Rlpx.uint2bin(Ticket.total_bytes(better_score)),
        Ticket.local_address(better_score),
        Ticket.device_signature(better_score)
      ]
      |> Rlp.encode!()
      |> Base16.encode(false)

    pid = RpcClient.connect()
    RpcClient.send_request(pid, 99, "dio_ticket", [hex])

    assert_receive {:rpc_response,
                    %{
                      "code" => -32001,
                      "message" => "too_low",
                      "data" => data
                    }},
                   5000

    usage = Base16.decode_int(data["usage"])
    assert usage > 0

    stored = TicketStore.find(device, fleet, epoch)
    assert Ticket.total_bytes(stored) == Ticket.total_bytes(high)

    RpcClient.disconnect(pid)
  end
end
