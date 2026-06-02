# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.TicketRequestPolicy do
  @moduledoc """
  Ticket refresh signaling thresholds by transport.

  See `docs/specs/ticket-request-policy.md` for the full comparison table.
  """

  @default_ws_usage_bytes 10_000_000
  @default_ws_interval_ms :timer.minutes(5)
  @ticket_request_deadline_ms 20_000
  @edge_refresh_interval_ms :timer.hours(8)

  @doc "WebSocket: minimum additional device usage since last `dio_ticket_request`."
  def ws_usage_bytes do
    Application.get_env(:diode, :rpc_ws_ticket_usage_bytes, @default_ws_usage_bytes)
  end

  @doc "WebSocket: minimum time between `dio_ticket_request` notifications."
  def ws_interval_ms do
    Application.get_env(:diode, :rpc_ws_ticket_interval_ms, @default_ws_interval_ms)
  end

  @doc "WebSocket: close the session if no `dio_ticket` arrives within this window after a request."
  def ws_deadline_ms do
    Application.get_env(:diode, :rpc_ws_ticket_deadline_ms, @ticket_request_deadline_ms)
  end

  @doc """
  WebSocket: whether to send `dio_ticket_request` (time or bytes since last notification).
  `markers` must include `:usage_at_last_request` and `:last_request_at`.
  """
  def ws_should_request?(markers, now_ms, usage) when is_map(markers) do
    time_elapsed = now_ms - markers.last_request_at >= ws_interval_ms()
    bytes_elapsed = usage - markers.usage_at_last_request >= ws_usage_bytes()
    time_elapsed or bytes_elapsed
  end

  @doc "Edge v2: unpaid bytes above this value trigger `ticket_request` on usage updates."
  def edge_send_threshold_bytes do
    grace = Diode.ticket_grace()
    grace - div(grace, 4)
  end

  @doc "Edge v2: periodic `ticket_request` interval after a successful ticket."
  def edge_refresh_interval_ms, do: @edge_refresh_interval_ms

  @doc "Edge v2: close the connection if no new ticket within this window after a request."
  def edge_deadline_ms, do: @ticket_request_deadline_ms

  @doc false
  def summary do
    %{
      websocket: %{
        notification: "dio_ticket_request",
        usage_bytes: ws_usage_bytes(),
        interval_ms: ws_interval_ms(),
        deadline_ms: ws_deadline_ms()
      },
      edge_v2: %{
        message: "ticket_request",
        min_protocol_version: 1001,
        send_threshold_bytes: edge_send_threshold_bytes(),
        refresh_interval_ms: edge_refresh_interval_ms(),
        deadline_ms: edge_deadline_ms(),
        ticket_grace_bytes: Diode.ticket_grace()
      }
    }
  end
end
