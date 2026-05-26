# Diode Server
# Copyright 2021-2025 Diode
# Licensed under the Diode License, Version 1.1
defmodule Model.FleetSqlTest do
  use ExUnit.Case, async: false

  @moonbeam_id Chains.Moonbeam.chain_id()
  @large_stake 1_099_000_000_000_000_000_000

  setup do
    Model.FleetSql.init()
    Model.FleetSql.delete_all()
    :ok
  end

  test "upsert stores uint256-sized stake values" do
    fleet = <<2::160>>

    Model.FleetSql.upsert(%{
      chain_id: @moonbeam_id,
      fleet: fleet,
      is_contract: 1,
      registry_exists: 1,
      stake: @large_stake,
      contract_checked_at: 1,
      registry_checked_at: 1,
      stake_checked_at: 1
    })

    assert %{stake: @large_stake} = Model.FleetSql.get(@moonbeam_id, fleet)
  end

  test "upsert round-trips legacy integer stake values" do
    fleet = <<3::160>>

    Model.FleetSql.upsert(%{
      chain_id: @moonbeam_id,
      fleet: fleet,
      is_contract: 1,
      registry_exists: 1,
      stake: 100,
      contract_checked_at: 1,
      registry_checked_at: 1,
      stake_checked_at: 1
    })

    assert %{stake: 100} = Model.FleetSql.get(@moonbeam_id, fleet)
  end
end
