# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule RegistryTest do
  alias Object.Ticket
  import Object.TicketV2
  alias Contract.{Fleet, Registry}
  use ExUnit.Case, async: false
  import TestHelper
  import Edge2Client
  import While

  setup_all do
    restart_chain()

    epoch = epoch()

    while epoch == epoch() do
      RemoteChain.RPC.rpc!(chain(), "evm_increaseTime", [div(chain().epoch_duration(), 3)])
      RemoteChain.RPC.rpc!(chain(), "evm_mine")
    end

    :ok
  end

  test "future ticket" do
    tck =
      ticketv2(
        chain_id: chain().chain_id(),
        server_id: Wallet.address!(Diode.wallet()),
        total_connections: 1,
        total_bytes: 0,
        local_address: "spam",
        epoch: epoch() + 1,
        fleet_contract: <<0::unsigned-size(160)>>,
        device_signature: Secp256k1.sign(clientkey(1), Hash.sha3_256("random"))
      )

    raw = Ticket.raw(tck)
    tx = Registry.submit_ticket_raw_tx(raw)
    {:error, %{"message" => message}} = Shell.call_tx(tx, "latest")
    assert String.contains?(message, "Wrong epoch")
  end

  test "zero ticket" do
    tck =
      ticketv2(
        chain_id: chain().chain_id(),
        server_id: Wallet.address!(Diode.wallet()),
        total_connections: 1,
        total_bytes: 0,
        local_address: "spam",
        epoch: epoch() - 1,
        fleet_contract: <<0::unsigned-size(160)>>
      )
      |> Ticket.device_sign(clientkey(1))

    raw = Ticket.raw(tck)
    tx = Registry.submit_ticket_raw_tx(raw)
    {:error, %{"message" => message}} = Shell.call_tx(tx, "latest")
    assert String.contains?(message, "execution reverted")
  end

  test "unregistered device" do
    # Ensuring queue is empty
    RemoteChain.RPC.rpc!(chain(), "evm_mine")

    # Creating new tx
    op = ac = Wallet.address!(Diode.wallet())
    fleet = Chains.Anvil.ensure_contract("FleetContract", [Base16.encode(op), Base16.encode(ac)])
    IO.puts("fleet: #{Base16.encode(fleet)}")

    client = clientid(1)
    assert Fleet.operator(chain(), fleet) == op
    assert Fleet.accountant(chain(), fleet) == ac
    assert Fleet.device_allowlisted?(chain(), fleet, client) == false

    tck =
      ticketv2(
        chain_id: chain().chain_id(),
        server_id: Wallet.address!(Diode.wallet()),
        total_connections: 1,
        total_bytes: 0,
        local_address: "spam",
        epoch: epoch() - 1,
        fleet_contract: fleet
      )
      |> Ticket.device_sign(clientkey(1))

    raw = Ticket.raw(tck)
    tx = Registry.submit_ticket_raw_tx(raw)

    {:error, %{"message" => message}} = Shell.call_tx(tx, "latest")
    assert String.contains?(message, "Unregistered device")

    # Now registering device
    Fleet.set_device_allowlist(chain().chain_id(), fleet, client, true)
    |> Shell.await_tx()

    assert Fleet.device_allowlisted?(chain(), fleet, client) == true
    RemoteChain.RPC.rpc!(chain(), "evm_mine")

    tck =
      ticketv2(
        chain_id: chain().chain_id(),
        server_id: Wallet.address!(Diode.wallet()),
        total_connections: 1,
        total_bytes: 0,
        local_address: "spam",
        epoch: epoch() - 1,
        fleet_contract: fleet
      )
      |> Ticket.device_sign(clientkey(1))

    raw = Ticket.raw(tck)
    tx = Registry.submit_ticket_raw_tx(raw)

    case Shell.call_tx(tx, "latest") do
      {:ok, "0x"} ->
        :ok

      {:error, %{"message" => message}} ->
        [msg, address] = String.split(message, "\0")
        # assert Base16.encode(address) == Base16.encode(Wallet.address!(clientid(1)))
        throw({msg, Base16.encode(address), Base16.encode(Wallet.address!(clientid(1)))})
    end
  end

  test "registered device (dev_contract)" do
    devfleet = chain().developer_fleet_address()
    assert Fleet.device_allowlisted?(chain(), devfleet, clientid(1)) == true

    tck =
      ticketv2(
        chain_id: chain().chain_id(),
        server_id: Wallet.address!(Diode.wallet()),
        total_connections: 1,
        total_bytes: 0,
        local_address: "spam",
        epoch: epoch() - 1,
        fleet_contract: devfleet
      )
      |> Ticket.device_sign(clientkey(1))

    raw = Ticket.raw(tck)
    tx = Registry.submit_ticket_raw_tx(raw)
    "0x" = Shell.call_tx!(tx, "latest")
  end
end
