# Diode Server
# Copyright 2021-2025 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.DeviceNotifyTest do
  use ExUnit.Case, async: false

  alias DiodeClient.{Object.TicketV2, Wallet}
  import TicketV2, only: [ticketv2: 1, device_sign: 2]

  @moonbeam_id Chains.Moonbeam.chain_id()

  setup do
    Model.FleetSql.init()
    Model.FleetSql.delete_all()
    :ok
  end

  test "maybe_notify publishes to all {:edge, device} subscribers" do
    device = Wallet.new() |> Wallet.address!()
    fleet = Wallet.new() |> Wallet.address!()
    PubSub.subscribe({:edge, device})

    assert :sent =
             Network.DeviceNotify.maybe_notify(
               device,
               @moonbeam_id,
               fleet,
               "warning",
               "fleet_not_found"
             )

    assert_receive {:device_notify, "warning", "fleet_not_found", message}, 1000
    assert message == Network.DeviceNotify.messages()["fleet_not_found"]
  end

  test "maybe_notify is rate-limited per device, chain, fleet, and code" do
    device = Wallet.new() |> Wallet.address!()
    fleet = Wallet.new() |> Wallet.address!()
    PubSub.subscribe({:edge, device})

    assert :sent =
             Network.DeviceNotify.maybe_notify(
               device,
               @moonbeam_id,
               fleet,
               "warning",
               "fleet_not_found"
             )

    assert_receive {:device_notify, _, _, _}, 1000

    assert :skipped =
             Network.DeviceNotify.maybe_notify(
               device,
               @moonbeam_id,
               fleet,
               "warning",
               "fleet_not_found"
             )

    refute_receive {:device_notify, _, _, _}, 50
  end

  test "maybe_notify skips unknown level or code" do
    device = Wallet.new() |> Wallet.address!()
    fleet = Wallet.new() |> Wallet.address!()
    PubSub.subscribe({:edge, device})

    assert :skipped =
             Network.DeviceNotify.maybe_notify(
               device,
               @moonbeam_id,
               fleet,
               "critical",
               "fleet_not_found"
             )

    assert :skipped =
             Network.DeviceNotify.maybe_notify(
               device,
               @moonbeam_id,
               fleet,
               "warning",
               "unknown_code"
             )

    refute_receive {:device_notify, _, _, _}, 50
  end

  test "notify_fleet_issue maps validation reasons and still allows informational only" do
    wallet = Wallet.new()
    device = Wallet.address!(wallet)
    fleet = Chains.Moonbeam.developer_fleet_address()
    PubSub.subscribe({:edge, device})

    ticket =
      ticketv2(
        chain_id: @moonbeam_id,
        server_id: Wallet.address!(Diode.wallet()),
        fleet_contract: fleet,
        total_connections: 1,
        total_bytes: 4096,
        local_address: "device_notify_test",
        epoch: 1
      )
      |> device_sign(Wallet.privkey!(wallet))

    now = System.os_time(:second)

    Model.FleetSql.upsert(%{
      chain_id: @moonbeam_id,
      fleet: fleet,
      is_contract: 0,
      registry_exists: 0,
      stake: 0,
      contract_checked_at: now,
      registry_checked_at: 0,
      stake_checked_at: 0
    })

    Application.put_env(:diode, :fleet_validation_registry_fn, fn _chain_id, _fleet ->
      %{
        exists: 0,
        currentBalance: 0,
        withdrawRequestSize: 0,
        withdrawableBalance: 0,
        currentEpoch: 0,
        score: 0
      }
    end)

    on_exit(fn ->
      Application.delete_env(:diode, :fleet_validation_registry_fn)
    end)

    assert :ok = FleetValidation.ensure_valid(ticket)
    assert_receive {:device_notify, "warning", "invalid_fleet_contract", _}, 1000

    assert :ok = FleetValidation.ensure_valid(ticket)
    refute_receive {:device_notify, _, _, _}, 50

    other_fleet = Wallet.new() |> Wallet.address!()

    Model.FleetSql.upsert(%{
      chain_id: @moonbeam_id,
      fleet: other_fleet,
      is_contract: 1,
      registry_exists: 0,
      stake: 0,
      contract_checked_at: now,
      registry_checked_at: 0,
      stake_checked_at: 0
    })

    ticket2 =
      ticketv2(
        chain_id: @moonbeam_id,
        server_id: Wallet.address!(Diode.wallet()),
        fleet_contract: other_fleet,
        total_connections: 1,
        total_bytes: 4096,
        local_address: "device_notify_test",
        epoch: 1
      )
      |> device_sign(Wallet.privkey!(wallet))

    assert :ok = FleetValidation.ensure_valid(ticket2)
    assert_receive {:device_notify, "warning", "fleet_not_found", _}, 1000
  end
end
