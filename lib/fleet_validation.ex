# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule FleetValidation do
  alias DiodeClient.{Base16, Object.Ticket}
  alias Model.{Ets, FleetSql}
  require Logger

  @stake_refresh_seconds 3600
  @warn_refresh_seconds 3600

  @diode_l1_chains [Chains.Diode, Chains.DiodeStaging, Chains.DiodeDev, Chains.Anvil]

  @spec ensure_valid(Ticket.t()) :: :ok | {:error, String.t()}
  def ensure_valid(ticket) do
    chain_id = Ticket.chain_id(ticket)
    fleet = Ticket.fleet_contract(ticket)
    row = refresh(chain_id, fleet, FleetSql.get(chain_id, fleet))

    with :ok <- validate_contract(row),
         :ok <- validate_registry(row, chain_id) do
      maybe_warn_zero_stake(row, chain_id)
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "Fleet validation failed on: #{Base16.encode(fleet)} @ #{chain_id}: #{inspect({:error, reason})}"
        )

        Network.DeviceNotify.notify_fleet_issue(ticket, reason)
        :ok
    end
  end

  defp refresh(chain_id, fleet, nil) do
    now = System.os_time(:second)
    row = empty_row(chain_id, fleet)

    refresh_fields(
      row,
      now,
      needs_contract?(nil, now),
      needs_registry?(nil, chain_id, now),
      needs_stake?(nil, chain_id, now)
    )
  end

  defp refresh(chain_id, _fleet, row) do
    now = System.os_time(:second)

    refresh_fields(
      row,
      now,
      needs_contract?(row, now),
      needs_registry?(row, chain_id, now),
      needs_stake?(row, chain_id, now)
    )
  end

  defp refresh_fields(row, now, refresh_contract?, refresh_registry?, refresh_stake?) do
    row =
      if refresh_contract? do
        contract? = contract?(row.chain_id, row.fleet)

        %{row | is_contract: bool_to_int(contract?), contract_checked_at: now}
      else
        row
      end

    row =
      if refresh_registry? or refresh_stake? do
        state = registry_fleet(row.chain_id, row.fleet)

        row
        |> maybe_update_registry(state, refresh_registry?, now)
        |> maybe_update_stake(state, refresh_stake?, now)
      else
        row
      end

    FleetSql.upsert(row)
    row
  end

  defp maybe_update_registry(row, _state, false, _now), do: row

  defp maybe_update_registry(row, state, true, now) do
    %{row | registry_exists: abi_bool_to_int(state.exists), registry_checked_at: now}
  end

  defp maybe_update_stake(row, _state, false, _now), do: row

  defp maybe_update_stake(row, state, true, now) do
    %{row | stake: state.currentBalance, stake_checked_at: now}
  end

  defp needs_contract?(nil, _now), do: true

  defp needs_contract?(row, now) do
    row.is_contract != 1 and now - row.contract_checked_at >= @stake_refresh_seconds
  end

  defp needs_registry?(nil, chain_id, _now), do: get_fleet_chain?(chain_id)

  defp needs_registry?(row, chain_id, now) do
    get_fleet_chain?(chain_id) and row.registry_exists != 1 and
      now - row.registry_checked_at >= @stake_refresh_seconds
  end

  defp needs_stake?(nil, chain_id, _now), do: moonbeam?(chain_id)

  defp needs_stake?(row, chain_id, now) do
    moonbeam?(chain_id) and now - row.stake_checked_at >= @stake_refresh_seconds
  end

  defp empty_row(chain_id, fleet) do
    %{
      chain_id: chain_id,
      fleet: fleet,
      is_contract: 0,
      registry_exists: 0,
      stake: 0,
      contract_checked_at: 0,
      registry_checked_at: 0,
      stake_checked_at: 0
    }
  end

  defp contract?(chain_id, fleet) do
    chain_id
    |> RemoteChain.RPCCache.get_code(Base16.encode(fleet))
    |> Base16.decode()
    |> case do
      "" -> false
      _ -> true
    end
  end

  defp validate_contract(row) do
    if row.is_contract == 1, do: :ok, else: {:error, "invalid fleet contract"}
  end

  defp validate_registry(row, chain_id) do
    cond do
      diode_l1?(chain_id) -> :ok
      row.registry_exists == 1 -> :ok
      true -> {:error, "unknown fleet"}
    end
  end

  defp maybe_warn_zero_stake(row, chain_id) do
    if moonbeam?(chain_id) and row.stake == 0 do
      key = {:fleet_zero_stake_warn, chain_id, row.fleet}
      now = System.os_time(:second)
      last = Ets.lookup(Diode, key, fn -> 0 end)

      if now - last >= @warn_refresh_seconds do
        Logger.warning(
          "fleet #{Base16.encode(row.fleet, false)} on chain #{chain_id} has 0 stake but device tickets are incoming"
        )

        Ets.put(Diode, key, now)
      end
    end
  end

  defp diode_l1?(chain_id) do
    RemoteChain.chainimpl(chain_id) in @diode_l1_chains
  end

  defp get_fleet_chain?(chain_id), do: not diode_l1?(chain_id)

  defp moonbeam?(chain_id), do: chain_id == Chains.Moonbeam.chain_id()

  defp registry_fleet(chain_id, fleet) do
    case Application.get_env(:diode, :fleet_validation_registry_fn) do
      fun when is_function(fun, 2) -> fun.(chain_id, fleet)
      _ -> Contract.Registry.fleet(chain_id, fleet)
    end
  end

  defp bool_to_int(true), do: 1
  defp bool_to_int(false), do: 0

  defp abi_bool_to_int(true), do: 1
  defp abi_bool_to_int(false), do: 0
  defp abi_bool_to_int(1), do: 1
  defp abi_bool_to_int(0), do: 0
end
