# Ticket request policy (Edge v2 vs WebSocket)

When device usage grows beyond the paid ticket allowance, the node must ask the client to submit a higher ticket. The **transport** determines the message shape and the **thresholds**.

Constants are defined in `Network.TicketRequestPolicy` (production defaults below). Tests may override WebSocket values via `Application.put_env/3`:

- `:rpc_ws_ticket_usage_bytes`
- `:rpc_ws_ticket_interval_ms`
- `:rpc_ws_ticket_deadline_ms`

## Comparison

| | **WebSocket JSON-RPC** | **Edge v2 (binary SSL)** |
|---|------------------------|---------------------------|
| **Client message** | JSON-RPC notification `dio_ticket_request` (no `id`) | RLP request `["ticket_request", usage]` |
| **Usage trigger** | **+10 MiB** since last notification | Unpaid **> 75%** of `Diode.ticket_grace()` (~30 MiB with default grace) |
| **Time trigger** | **5 minutes** since last notification | **8 hours** after each accepted ticket (`:ticket_refresh`) |
| **Trigger rule** | Whichever condition is met **first** | Usage: on `{:device_usage, _}`; time: debounced refresh timer |
| **Also on connect** | No (only after first `dio_ticket`) | Yes (`must_have_ticket` on accept + after `hello` if `version > 1000`) |
| **Min protocol version** | N/A (WebSocket) | `version > 1000` (v1000 does not receive `ticket_request`) |
| **Deadline** | **20 s** — close WebSocket if no new `dio_ticket` | **20 s** — close Edge if `last_ticket` unchanged |
| **Implementation** | `Network.RpcWsTicketBilling` | `Network.EdgeV2` (`must_have_ticket` / `send_ticket_request`) |

Default `Diode.ticket_grace()` is `1024 * 40_960` bytes (~40 MiB). Edge send threshold is `grace - grace/4` (75%).

## WebSocket notification

```json
{
  "jsonrpc": "2.0",
  "method": "dio_ticket_request",
  "params": {
    "usage": 10485760,
    "fleet": "0x6000000000000000000000000000000000000000"
  }
}
```

- `usage` — decimal integer, current `TicketStore.device_usage/1` for the device (same baseline as Edge `ticket_request`).
- `fleet` — `0x`-prefixed hex fleet contract from the session ticket.

After sending, the server starts a **20 s** timer. A successful `dio_ticket` on the same WebSocket cancels the timer and resets billing markers.

## Client responsibilities

- On `dio_ticket_request` or synchronous `too_low`, submit `dio_ticket` with `total_bytes` ≥ `usage` (plus score rules in `feature-message.md`).
- Edge clients must handle binary `ticket_request`; WebSocket clients must handle `dio_ticket_request`.

## Related specs

- `feature-message.md` — `dio_ticket`, `too_low`
- `feature-wireguard-exit-node.md` — WireGuard accounting drives `device_usage`
