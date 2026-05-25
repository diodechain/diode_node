# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.TicketSubmissionTest do
  use ExUnit.Case, async: false
  import TestHelper
  alias DiodeClient.Object.TicketV2, as: Ticket
  alias DiodeClient.{Base16, Rlp, Rlpx, Wallet}
  import Ticket, only: [ticketv2: 1]
  import Edge2Client, only: [clientid: 1]

  @chain Chains.Anvil
  @ticket_grace 4096

  setup do
    reset()
    :ok
  end

  test "submit stores valid ticketv2 in TicketStore" do
    wallet = clientid(1)
    ticket = build_ticket(wallet, total_bytes: @ticket_grace, total_connections: 1)

    assert {:ok, _} = Network.TicketSubmission.submit(ticket, wallet)

    assert TicketStore.find(
             Wallet.address!(wallet),
             Ticket.fleet_contract(ticket),
             Ticket.epoch(ticket)
           )
  end

  test "decode_rlp_ticket and dio_ticket path store via execute_dio" do
    hex = Edge2Client.encode_ticket_for_dio_ticket(1)
    assert {nil, 200, _} = Network.Rpc.execute_dio("dio_ticket", [hex], %{connection_state: true})

    wallet = clientid(1)
    fleet = RemoteChain.developer_fleet_address(@chain)
    epoch = RemoteChain.epoch(@chain) - 1

    assert TicketStore.find(Wallet.address!(wallet), fleet, epoch)
  end

  test "validation errors match Edge messages" do
    wallet = clientid(1)
    current = RemoteChain.epoch(@chain)

    too_low =
      build_ticket(wallet,
        epoch: current - 5,
        total_bytes: @ticket_grace,
        total_connections: 1
      )

    assert {:error, "epoch number too low"} =
             Network.TicketSubmission.submit(too_low, wallet)

    too_high =
      build_ticket(wallet, epoch: current + 1, total_bytes: @ticket_grace, total_connections: 1)

    assert {:error, "epoch number too high"} =
             Network.TicketSubmission.submit(too_high, wallet)

    bad_wallet = Wallet.new()

    valid_epoch =
      build_ticket(wallet, total_bytes: @ticket_grace, total_connections: 1)

    assert {:error, "signature mismatch"} =
             Network.TicketSubmission.submit(valid_epoch, bad_wallet)
  end

  test "too_low when submitting lower-score ticket after higher" do
    wallet = clientid(1)
    epoch = RemoteChain.epoch(@chain) - 1

    high =
      build_ticket(wallet, epoch: epoch, total_bytes: 1_000_000, total_connections: 100)

    assert {:ok, _} = Network.TicketSubmission.submit(high, wallet)

    low = build_ticket(wallet, epoch: epoch, total_bytes: @ticket_grace, total_connections: 1)

    assert {:error, "too_low", last} = Network.TicketSubmission.submit(low, wallet)

    data = Network.TicketSubmission.too_low_data(last, wallet)
    usage = Base16.decode_int(data["usage"])
    assert usage >= Ticket.total_bytes(last)

    assert data["summary"]["total_bytes"] ==
             Base16.encode(Ticket.total_bytes(last), false)

    assert data["summary"]["total_connections"] ==
             Base16.encode(Ticket.total_connections(last), false)
  end

  test "dio_ticket too_low includes data.usage and data.summary" do
    wallet = clientid(1)
    epoch = RemoteChain.epoch(@chain) - 1

    high =
      build_ticket(wallet, epoch: epoch, total_bytes: 1_000_000, total_connections: 100)

    assert {:ok, _} = Network.TicketSubmission.submit(high, wallet)

    low = build_ticket(wallet, epoch: epoch, total_bytes: @ticket_grace, total_connections: 1)

    low_hex =
      [
        "ticketv2",
        Rlpx.uint2bin(Ticket.chain_id(low)),
        Rlpx.uint2bin(Ticket.epoch(low)),
        Ticket.fleet_contract(low),
        Rlpx.uint2bin(Ticket.total_connections(low)),
        Rlpx.uint2bin(Ticket.total_bytes(low)),
        Ticket.local_address(low),
        Ticket.device_signature(low)
      ]
      |> Rlp.encode!()
      |> Base16.encode(false)

    assert {nil, 400, %{"code" => -32001, "message" => "too_low", "data" => data}} =
             Network.Rpc.execute_dio("dio_ticket", [low_hex], %{connection_state: true})

    assert Map.has_key?(data, "usage")
    assert Map.has_key?(data["summary"], "total_bytes")
    assert Map.has_key?(data["summary"], "epoch")
  end

  test "invalid RLP decode" do
    assert {:error, "invalid ticket"} = Network.TicketSubmission.decode_rlp_ticket(["nope"])
  end

  test "rejects ticket with non-contract fleet address" do
    wallet = clientid(1)
    invalid_fleet = Wallet.new() |> Wallet.address!()

    ticket =
      build_ticket(wallet,
        fleet_contract: invalid_fleet,
        total_bytes: @ticket_grace,
        total_connections: 1
      )

    assert {:error, "invalid fleet contract"} = Network.TicketSubmission.submit(ticket, wallet)
  end

  test "rejects ticket with zero address fleet" do
    wallet = clientid(1)

    ticket =
      build_ticket(wallet,
        fleet_contract: <<0::160>>,
        total_bytes: @ticket_grace,
        total_connections: 1
      )

    assert {:error, "invalid fleet contract"} = Network.TicketSubmission.submit(ticket, wallet)
  end

  defp build_ticket(wallet, opts) do
    fleet = Keyword.get(opts, :fleet_contract, RemoteChain.developer_fleet_address(@chain))
    epoch = opts[:epoch] || RemoteChain.epoch(@chain) - 1
    key = Wallet.privkey!(wallet)

    ticketv2(
      chain_id: @chain.chain_id(),
      server_id: Wallet.address!(Diode.wallet()),
      total_connections: Keyword.get(opts, :total_connections, 1),
      total_bytes: Keyword.get(opts, :total_bytes, @ticket_grace),
      local_address: "ticket_submission_test",
      epoch: epoch,
      fleet_contract: fleet
    )
    |> Ticket.device_sign(key)
  end
end
