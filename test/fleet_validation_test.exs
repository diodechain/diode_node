# Diode Server
# Copyright 2021-2025 Diode
# Licensed under the Diode License, Version 1.1
defmodule FleetValidationTest do
  use ExUnit.Case, async: false

  alias DiodeClient.{ABI, Object.TicketV2, Wallet}
  import TicketV2, only: [ticketv2: 1]

  @moonbeam_id Chains.Moonbeam.chain_id()

  setup do
    Model.FleetSql.init()
    Model.FleetSql.delete_all()

    on_exit(fn ->
      Application.delete_env(:diode, :fleet_validation_registry_fn)
    end)

    :ok
  end

  test "ABI bool decodes to integer values" do
    assert [1] = ABI.decode_args(["bool"], ABI.encode_args(["bool"], [true]))
    assert [0] = ABI.decode_args(["bool"], ABI.encode_args(["bool"], [false]))
  end

  test "GetFleet bool field decodes to integer exists" do
    encoded =
      ABI.encode_args(
        ["(bool, uint256, uint256, uint256, uint256, uint256)"],
        [[true, 0, 0, 0, 0, 0]]
      )

    [[exists, _current_balance, _, _, _, _]] =
      ABI.decode_args(["(bool, uint256, uint256, uint256, uint256, uint256)"], encoded)

    assert exists == 1
  end

  test "ensure_valid stores registry_exists when GetFleet returns integer exists" do
    fleet = Chains.Moonbeam.developer_fleet_address()
    now = System.os_time(:second)
    large_stake = 1_099_000_000_000_000_000_000

    Model.FleetSql.upsert(%{
      chain_id: @moonbeam_id,
      fleet: fleet,
      is_contract: 1,
      registry_exists: 0,
      stake: 0,
      contract_checked_at: now,
      registry_checked_at: 0,
      stake_checked_at: 0
    })

    Application.put_env(:diode, :fleet_validation_registry_fn, fn _chain_id, _fleet ->
      %{
        exists: 1,
        currentBalance: large_stake,
        withdrawRequestSize: 0,
        withdrawableBalance: 0,
        currentEpoch: 0,
        score: 0
      }
    end)

    ticket =
      ticketv2(
        chain_id: @moonbeam_id,
        server_id: Wallet.address!(Diode.wallet()),
        fleet_contract: fleet,
        total_connections: 1,
        total_bytes: 4096,
        local_address: "fleet_validation_test",
        epoch: 1,
        device_signature: <<0::520>>
      )

    assert :ok = FleetValidation.ensure_valid(ticket)

    row = Model.FleetSql.get(@moonbeam_id, fleet)
    assert row.registry_exists == 1
    assert row.stake == large_stake
    assert row.registry_checked_at > 0
  end

  test "ensure_valid rejects fleet when GetFleet returns integer exists 0" do
    fleet = Chains.Moonbeam.developer_fleet_address()
    now = System.os_time(:second)

    Model.FleetSql.upsert(%{
      chain_id: @moonbeam_id,
      fleet: fleet,
      is_contract: 1,
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

    ticket =
      ticketv2(
        chain_id: @moonbeam_id,
        server_id: Wallet.address!(Diode.wallet()),
        fleet_contract: fleet,
        total_connections: 1,
        total_bytes: 4096,
        local_address: "fleet_validation_test",
        epoch: 1,
        device_signature: <<0::520>>
      )

    assert :ok = FleetValidation.ensure_valid(ticket)

    row = Model.FleetSql.get(@moonbeam_id, fleet)
    assert row.registry_exists == 0
  end
end
