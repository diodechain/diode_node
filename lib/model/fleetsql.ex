# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Model.FleetSql do
  alias Model.Sql

  defp query!(sql, params \\ []) do
    Sql.query!(__MODULE__, sql, params)
  end

  def init() do
    query!("""
        CREATE TABLE IF NOT EXISTS fleets (
          chain_id INTEGER NOT NULL,
          fleet BLOB NOT NULL,
          is_contract INTEGER NOT NULL DEFAULT 0,
          registry_exists INTEGER NOT NULL DEFAULT 0,
          stake TEXT NOT NULL DEFAULT '0',
          contract_checked_at INTEGER NOT NULL DEFAULT 0,
          registry_checked_at INTEGER NOT NULL DEFAULT 0,
          stake_checked_at INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (chain_id, fleet)
        )
    """)

    migrate_stake_to_text!()
  end

  defp migrate_stake_to_text!() do
    case stake_column_type() do
      "TEXT" -> :ok
      _ -> recreate_fleets_with_text_stake!()
    end
  end

  defp stake_column_type() do
    query!("PRAGMA table_info(fleets)")
    |> Enum.find_value(fn row ->
      case row do
        [_cid, "stake", type | _] -> type
        _ -> nil
      end
    end)
  end

  defp recreate_fleets_with_text_stake!() do
    query!("""
      CREATE TABLE fleets_stake_text (
        chain_id INTEGER NOT NULL,
        fleet BLOB NOT NULL,
        is_contract INTEGER NOT NULL DEFAULT 0,
        registry_exists INTEGER NOT NULL DEFAULT 0,
        stake TEXT NOT NULL DEFAULT '0',
        contract_checked_at INTEGER NOT NULL DEFAULT 0,
        registry_checked_at INTEGER NOT NULL DEFAULT 0,
        stake_checked_at INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (chain_id, fleet)
      )
    """)

    query!("""
      INSERT INTO fleets_stake_text (
        chain_id, fleet, is_contract, registry_exists, stake,
        contract_checked_at, registry_checked_at, stake_checked_at
      )
      SELECT chain_id, fleet, is_contract, registry_exists,
             CASE
               WHEN stake IS NULL THEN '0'
               WHEN typeof(stake) = 'text' THEN stake
               WHEN typeof(stake) = 'integer' THEN CAST(stake AS TEXT)
               WHEN typeof(stake) = 'real' THEN printf('%.0f', stake)
               ELSE '0'
             END,
             contract_checked_at, registry_checked_at, stake_checked_at
      FROM fleets
    """)

    query!("DROP TABLE fleets")
    query!("ALTER TABLE fleets_stake_text RENAME TO fleets")
  end

  def get(chain_id, fleet = <<_::160>>) when is_integer(chain_id) do
    case query!(
           """
           SELECT is_contract, registry_exists, stake, contract_checked_at,
                  registry_checked_at, stake_checked_at
           FROM fleets WHERE chain_id = ?1 AND fleet = ?2
           """,
           [chain_id, fleet]
         ) do
      [] ->
        nil

      [
        [
          is_contract,
          registry_exists,
          stake,
          contract_checked_at,
          registry_checked_at,
          stake_checked_at
        ]
      ] ->
        %{
          chain_id: chain_id,
          fleet: fleet,
          is_contract: is_contract,
          registry_exists: registry_exists,
          stake: decode_stake(stake),
          contract_checked_at: contract_checked_at,
          registry_checked_at: registry_checked_at,
          stake_checked_at: stake_checked_at
        }
    end
  end

  def upsert(row) do
    query!(
      """
      REPLACE INTO fleets (
        chain_id, fleet, is_contract, registry_exists, stake,
        contract_checked_at, registry_checked_at, stake_checked_at
      ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
      """,
      [
        row.chain_id,
        row.fleet,
        row.is_contract,
        row.registry_exists,
        encode_stake(row.stake),
        row.contract_checked_at,
        row.registry_checked_at,
        row.stake_checked_at
      ]
    )

    row
  end

  defp encode_stake(stake) when is_integer(stake), do: Integer.to_string(stake)
  defp encode_stake(stake) when is_binary(stake), do: stake

  defp decode_stake(stake) when is_integer(stake), do: stake

  defp decode_stake(stake) when is_float(stake) do
    stake |> Float.round() |> trunc()
  end

  defp decode_stake(stake) when is_binary(stake) do
    case Integer.parse(stake) do
      {n, ""} -> n
      _ -> 0
    end
  end

  def delete_all() do
    query!("DELETE FROM fleets")
  end
end
