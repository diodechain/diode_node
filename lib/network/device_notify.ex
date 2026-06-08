# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.DeviceNotify do
  @moduledoc """
  Rate-limited server → device notifications fan-out via `PubSub` topic `{:edge, device}`.

  Edge v2 connections translate to binary `notify`; authenticated WebSockets to `dio_notify`.
  """
  alias DiodeClient.Object.Ticket
  alias Model.Ets

  @refresh_seconds 3600
  @levels ~w(debug notice warning error)

  @messages %{
    "fleet_not_found" => "Fleet is not registered on this chain",
    "invalid_fleet_contract" => "Fleet address is not a contract"
  }

  @fleet_issue_codes %{
    "unknown fleet" => "fleet_not_found",
    "invalid fleet contract" => "invalid_fleet_contract"
  }

  @doc false
  def messages, do: @messages

  @doc """
  Emit a notification when rate limit allows (per device, chain, fleet, code).

  Returns `:sent` or `:skipped`.
  """
  @spec maybe_notify(binary(), non_neg_integer(), binary(), String.t(), String.t()) ::
          :sent | :skipped
  def maybe_notify(device, chain_id, fleet, level, code)
      when is_binary(device) and byte_size(device) == 20 and is_binary(fleet) and
             is_integer(chain_id) and chain_id >= 0 do
    with :ok <- validate_level(level),
         :ok <- validate_code(code),
         true <- rate_limit_ok?(device, chain_id, fleet, code) do
      message = Map.fetch!(@messages, code)
      PubSub.publish({:edge, device}, {:device_notify, level, code, message})
      :sent
    else
      _ -> :skipped
    end
  end

  @doc "Informational fleet validation notice; tickets are not rejected."
  @spec notify_fleet_issue(Ticket.t(), String.t()) :: :sent | :skipped
  def notify_fleet_issue(ticket, reason) when is_binary(reason) do
    with code when is_binary(code) <- Map.get(@fleet_issue_codes, reason),
         {:ok, device} <- device_address_safe(ticket) do
      maybe_notify(
        device,
        Ticket.chain_id(ticket),
        Ticket.fleet_contract(ticket),
        "warning",
        code
      )
    else
      _ -> :skipped
    end
  end

  defp device_address_safe(ticket) do
    {:ok, Ticket.device_address(ticket)}
  rescue
    MatchError -> :error
  end

  defp validate_level(level) when level in @levels, do: :ok
  defp validate_level(_), do: :error

  defp validate_code(code) when is_map_key(@messages, code), do: :ok
  defp validate_code(_), do: :error

  defp rate_limit_ok?(device, chain_id, fleet, code) do
    key = {:device_notify, device, chain_id, fleet, code}
    now = System.os_time(:second)
    last = Ets.lookup(Diode, key, fn -> 0 end)

    if now - last >= @refresh_seconds do
      Ets.put(Diode, key, now)
      true
    else
      false
    end
  end
end
