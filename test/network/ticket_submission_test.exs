# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.TicketSubmissionTest do
  use ExUnit.Case, async: false
  import TestHelper
  alias DiodeClient.Object.TicketV2, as: Ticket
  alias DiodeClient.Wallet
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

    assert {:error, "too_low", _last} = Network.TicketSubmission.submit(low, wallet)
  end

  test "invalid RLP decode" do
    assert {:error, "invalid ticket"} = Network.TicketSubmission.decode_rlp_ticket(["nope"])
  end

  defp build_ticket(wallet, opts) do
    fleet = RemoteChain.developer_fleet_address(@chain)
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
