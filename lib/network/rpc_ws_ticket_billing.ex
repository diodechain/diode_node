# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.RpcWsTicketBilling do
  @moduledoc """
  Mid-session billing nudges for WebSocket JSON-RPC (`dio_ticket_request`).

  Runs in the `Network.RpcWs` connection process. See `Network.TicketRequestPolicy`.
  """
  alias DiodeClient.Base16
  alias Network.TicketRequestPolicy, as: Policy
  alias TicketStore

  @state_key {:rpc_ws_ticket_billing, :state}

  @type state :: %{
          device: binary(),
          fleet: binary(),
          usage_at_last_request: non_neg_integer(),
          last_request_at: integer(),
          ticket_version: non_neg_integer(),
          pending_ticket_version: non_neg_integer() | nil,
          interval_ref: reference() | nil,
          deadline_ref: reference() | nil
        }

  @doc "Start billing timers after a successful `dio_ticket` on this connection."
  @spec on_ticket_accepted(binary(), binary()) :: :ok
  def on_ticket_accepted(device, fleet) when is_binary(device) and is_binary(fleet) do
    now = mono()

    case Process.get(@state_key) do
      nil ->
        activate(device, fleet, now)

      state ->
        usage = TicketStore.device_usage(device)

        state =
          state
          |> cancel_deadline()
          |> Map.merge(%{
            device: device,
            fleet: fleet,
            ticket_version: state.ticket_version + 1,
            pending_ticket_version: nil,
            usage_at_last_request: usage,
            last_request_at: now,
            deadline_ref: nil
          })

        put(state)
    end

    :ok
  end

  @doc "Handle `PubSub` `{:device_usage, device}` on the websocket process."
  @spec on_device_usage(binary()) :: :ok
  def on_device_usage(device) when is_binary(device) do
    case Process.get(@state_key) do
      %{device: ^device} = state -> maybe_send_request(state, :usage)
      _ -> :ok
    end
  end

  @doc "Periodic timer callback."
  @spec on_interval :: :ok
  def on_interval do
    case Process.get(@state_key) do
      nil ->
        :ok

      state ->
        state = %{state | interval_ref: schedule_interval()}
        put(state)
        maybe_send_request(state, :interval)
    end
  end

  @doc "Close the websocket if the client missed the post-request deadline."
  @spec on_deadline(non_neg_integer()) :: :ok
  def on_deadline(required_version) when is_integer(required_version) and required_version >= 0 do
    case Process.get(@state_key) do
      %{ticket_version: version, pending_ticket_version: ^required_version}
      when version < required_version ->
        send(self(), :rpc_ws_close_ticket_deadline)
        :ok

      _ ->
        :ok
    end
  end

  @doc "Cancel timers and drop billing state (websocket terminate)."
  @spec deactivate :: :ok
  def deactivate do
    case Process.get(@state_key) do
      nil -> :ok
      state -> cleanup(state)
    end

    :ok
  end

  @doc false
  def should_request?(state, now_ms, usage) do
    time_elapsed = now_ms - state.last_request_at >= Policy.ws_interval_ms()
    bytes_elapsed = usage - state.usage_at_last_request >= Policy.ws_usage_bytes()
    time_elapsed or bytes_elapsed
  end

  @doc false
  def notification(usage, fleet) do
    %{
      "jsonrpc" => "2.0",
      "method" => "dio_ticket_request",
      "params" => %{
        "usage" => usage,
        "fleet" => Base16.encode(fleet, false)
      }
    }
  end

  defp activate(device, fleet, now) do
    usage = TicketStore.device_usage(device)

    state = %{
      device: device,
      fleet: fleet,
      usage_at_last_request: usage,
      last_request_at: now,
      ticket_version: 1,
      pending_ticket_version: nil,
      interval_ref: schedule_interval(),
      deadline_ref: nil
    }

    put(state)
    maybe_send_request(state, :activate)
    :ok
  end

  defp maybe_send_request(state, _reason) do
    usage = TicketStore.device_usage(state.device)
    now = mono()

    if should_request?(state, now, usage) do
      send_request(state, now, usage)
    end

    :ok
  end

  defp send_request(state, now, usage) do
    state = cancel_deadline(state)
    send(self(), {:rpc_ws_push_notification, notification(usage, state.fleet)})

    required_version = state.ticket_version + 1

    deadline_ref =
      Process.send_after(
        self(),
        {:rpc_ws_ticket_deadline, required_version},
        Policy.ws_deadline_ms()
      )

    put(%{
      state
      | last_request_at: now,
        usage_at_last_request: usage,
        pending_ticket_version: required_version,
        deadline_ref: deadline_ref
    })

    :ok
  end

  defp schedule_interval do
    Process.send_after(self(), :rpc_ws_ticket_interval, Policy.ws_interval_ms())
  end

  defp cancel_deadline(%{deadline_ref: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    %{state | deadline_ref: nil}
  end

  defp cancel_deadline(state), do: state

  defp cleanup(%{interval_ref: interval_ref, deadline_ref: deadline_ref} = state) do
    if is_reference(interval_ref), do: Process.cancel_timer(interval_ref)
    if is_reference(deadline_ref), do: Process.cancel_timer(deadline_ref)
    Process.delete(@state_key)
    state
  end

  defp put(state), do: Process.put(@state_key, state)

  defp mono, do: System.monotonic_time(:millisecond)
end
