# TURN Relay Service Specification v0.1.2

**Spec type:** Feature  
**Path:** `docs/specs/feature-turn-support.md`

## Overview

This feature embeds the [xturn](https://github.com/xirsys/xturn) TURN server (Elixir, Apache-2.0) into the Diode node using the **published Hex package** [`xturn`](https://hex.pm/packages/xturn) (e.g. `~> 0.1.2`) **without forking xturn** for authentication or baseline operation. Browsers and other WebRTC clients use **generic TURN** on a **public UDP/TCP listener** (default port **19403**). Access is **permissioned**: only clients that have authenticated with a valid ticket may obtain TURN credentials through Edge or RPC. **Per-device TURN passwords** are validated by a **Diode-owned pipeline module** that **replaces** `Xirsys.XTurn.Actions.Authenticates` via `config :xturn, :pipes` (see [Pipeline authentication](#pipeline-authentication-replacing-xturnactionsauthenticates)). **Bandwidth** consumed on the relay path is recorded with `TicketStore.increase_device_usage/2`, consistent with WireGuard exit and port forwarding. **Vendorizing xturn** is reserved for optional follow-up (e.g. exported allocation byte counters); v1 implements accounting via **hooks** where possible (see [Upstream dependency review](#upstream-dependency-review-xturn--xturn_sockets)).

**Integration context:** Extends `Network.EdgeV2` with a `["turnopen"]` command (no extra args; same idea as `portopen`), extends `Network.Rpc` (and `Network.RpcWs` for connection-state methods if needed) with a corresponding JSON-RPC method, integrates with `TicketStore`, adds configuration in `Diode.Config`, and starts a thin `TurnService` from `Diode` when enabled. Depends on in-tree **xturn** (`lib/xturn/`), vendored **xmedialib** (`vendor/xmedialib/`), and Hex **xturn_sockets** / **xturn_cache**.

## Upstream dependency review (xturn / xturn_sockets)

This section answers: **Can bandwidth tracking use existing hooks, or is vendorizing xturn required?**

### What exists today

1. **`xturn_sockets` (Hex, e.g. 0.1.1)**  
   - Exposes **`client_hooks`** and **`peer_hooks`** via `Application.get_env(:xturn, :client_hooks, [])` and `:peer_hooks`.  
   - **UDP listener** invokes `Socket.send_to_client_hooks/1` with a `%Conn{}` for **every** incoming UDP datagram to the TURN listener (control + relay-related STUN/TURN payloads).  
   - Hooks receive `GenServer.cast(pid, {:process_message, :client | :peer, data})`.

2. **`xturn` `Allocate.Client`**  
   - Maintains per-allocation **`bytes_in`** and **`bytes_out`** in internal state and updates them on relay paths.  
   - Calls **`Socket.send_to_peer_hooks/1`** only in the **peer → client** relay path (UDP on the allocated relay socket), with a map `%{client_ip, client_port, message}` (payload toward the TURN client).  
   - There is **no public** `get_stats/1` (or similar) on `Allocate.Client` for those counters.

3. **Authentication** (`Xirsys.XTurn.Actions.Authenticates`)  
   - Stock xturn validates STUN MESSAGE-INTEGRITY against a **single global** `username` / `credential` from `Application.get_env(:xturn, :authentication)`.  
   - **Diode does not modify Hex xturn for this.** Instead, implement an **alternative module** (same pipeline contract as upstream `Authenticates`) that resolves credentials from the Diode credential store (populated by `turnopen`) and inject it by setting **`config :xturn, :pipes`** so that **every pipeline that listed `Xirsys.XTurn.Actions.Authenticates` uses the Diode module instead.** See [Pipeline authentication](#pipeline-authentication-replacing-xturnactionsauthenticates).

### Pipeline authentication (replacing `Xirsys.XTurn.Actions.Authenticates`)

xturn routes STUN/TURN requests through a **`pipes`** map: each method (`:allocate`, `:refresh`, `:channelbind`, `:createperm`, `:send`, `:channeldata`, …) has an ordered list of action modules. The stock config includes `Xirsys.XTurn.Actions.Authenticates` in the pipelines that require auth (e.g. allocate, refresh, channel bind, create permission—not necessarily in `send` / `channeldata` in the same way).

**Implementations MUST:**

1. Add a module (e.g. `Diode.Turn.Authenticates`—exact name is implementation-defined) that implements the **same `process/1` contract** as `Xirsys.XTurn.Actions.Authenticates` against `%Xirsys.Sockets.Conn{}`: decode STUN, verify MESSAGE-INTEGRITY using the **long-term credential** for the `username` in the packet, where that credential is **only** one issued by `turnopen` and stored in the Diode credential store (not the global config pair).
2. At runtime (or in `config/runtime.exs`), set `config :xturn, :pipes` to a **copy of xturn’s default pipes** with **`Xirsys.XTurn.Actions.Authenticates` replaced by the Diode module** in every list where it appears. No changes to the Hex package source tree.
3. Keep `config :xturn, :authentication` compatible with xturn startup if required; the Diode authenticator is the source of truth for **which** usernames are valid.

**Illustrative shape (not normative module names):**

```elixir
# Pseudocode: merge with xturn defaults, swap only Authenticates
config :xturn,
  pipes: %{
    allocate: [
      Xirsys.XTurn.Actions.HasRequestedTransport,
      Xirsys.XTurn.Actions.NotAllocationExists,
      Diode.Turn.Authenticates,
      Xirsys.XTurn.Actions.Allocate
    ],
    refresh: [Diode.Turn.Authenticates, Xirsys.XTurn.Actions.Refresh],
    channelbind: [Diode.Turn.Authenticates, Xirsys.XTurn.Actions.ChannelBind],
    createperm: [Diode.Turn.Authenticates, Xirsys.XTurn.Actions.CreatePerm],
    send: [Xirsys.XTurn.Actions.SendIndication],
    channeldata: [Xirsys.XTurn.Actions.ChannelData]
  }
```

Implementations MUST match the **exact** method keys and module lists shipped with the pinned `xturn` version, substituting **only** the `Authenticates` entries.

### Hooks vs accurate relay accounting

| Approach | Pros | Cons |
|----------|------|------|
| **Hooks only (no xturn fork)** | No fork; use `client_hooks` + `peer_hooks` | Client hook sees **all** traffic to the TURN port (allocate, refresh, channel bind, send indication, channel data), not “relay payload only.” Peer hook does not include **username**; correlating bytes to `device_address` needs an **ETS map** (e.g. keyed by STUN `USERNAME` after parse, or by `{client_ip, client_port}` once bound) maintained by the Diode app. Double-counting and signaling overhead must be defined or filtered. |
| **Poll internal counters** | Matches “bytes on allocation” intent | Counters exist in `Allocate.Client` but are **not exported**; requires **patch** (or fork) to expose stats or invoke a callback. |
| **Vendor patch (recommended for billing-grade relay bytes)** | Add `TurnAccounting` callback or `telemetry` events when `bytes_in` / `bytes_out` increase, or `handle_info`/`terminate` flush, with **username** (or allocation id → device) in scope | Requires maintaining a **fork or vendored copy** under `deps/` or `vendor/xturn` with small, reviewed diffs. |

**Conclusion:**  
- **Hooks alone** are *insufficient* for precise “all bytes on relay addresses only” without either **parsing/filtering STUN** in app code or **accepting signaling overhead** in the count. They *can* support a **best-effort** total if product accepts counting **all UDP to the TURN listener** plus **peer-hook** path, with explicit rules.  
- **No first-class “bandwidth hook” with username + relay-only bytes** exists in stock xturn. **Either** implement accounting in application code on top of hooks + ETS correlation **or** **vendorize xturn** later to expose per-allocation byte deltas. **Authentication is not vendorized:** use **`:pipes`** + a Diode `Authenticates` module (Hex xturn unchanged).  
- **Credential validation** is implemented by the **injected pipeline module** and the credential store backing `turnopen`, not by hot-patching `Xirsys.XTurn.Actions.Authenticates` in `deps/`.

**References:** [xturn on GitHub](https://github.com/xirsys/xturn), [xturn on Hex](https://hex.pm/packages/xturn).

## Design Principles

1. **Ticket-authenticated credentials only.** `turnopen` succeeds only for authenticated Edge sessions or websocket RPC with a valid ticket; anonymous clients cannot obtain TURN passwords.
2. **Stable credentials per 24h window.** Repeated `turnopen` for the same device returns the **same** username/password until expiry; then a new pair is issued and old credentials are removed server-side.
3. **Traffic-accounted.** Relay traffic increments usage via `TicketStore.increase_device_usage/2` per device, using the accounting strategy chosen in [Bandwidth accounting strategy](#bandwidth-accounting-strategy) (hooks-based or patched).
4. **Browser-generic TURN.** Expose standard TURN URIs (UDP/TCP as configured) on the public port; realm and server IP/host must be consistent with xturn config and what clients embed in ICE.
5. **Configurable and optional.** Feature can be disabled via config; default listener **19403** overridable via env.
6. **Hex xturn unchanged for auth.** Per-device TURN credentials are enforced by a **Diode pipeline module** listed in **`config :xturn, :pipes`** in place of `Xirsys.XTurn.Actions.Authenticates`, not by editing dependency sources.

## Files to Modify or Create

| File | Action | Purpose |
|------|--------|---------|
| `mix.exs` | Modify | Add `{:xturn, "~> 0.1"}` (or pinned version); resolve conflicts with `xmedialib` / `xturn_sockets` versions |
| `lib/turn/` or `lib/turn_service.ex` | **Create** | Supervision wrapper, config merge, optional accounting GenServer |
| `lib/diode/turn/credential_store.ex` (path/name TBD) | **Create** | ETS: `device_address` → `{username, password, expires_at}`; issue/lookup for `turnopen`; lookup by `username` for MESSAGE-INTEGRITY |
| `lib/diode/turn/authenticates.ex` (name TBD) | **Create** | Pipeline module **injected via** `config :xturn, :pipes` **instead of** `Xirsys.XTurn.Actions.Authenticates`; validate MESSAGE-INTEGRITY against credential store |
| `lib/network/edge_v2.ex` | Modify | `["turnopen"]` clause |
| `lib/network/rpc.ex` | Modify | e.g. `dio_turn_open`; add to `@local_dio_methods` |
| `lib/network/rpc_ws.ex` | Modify | If method needs ticket/session, add to `needs_connection_state?/1` |
| `lib/config.ex` | Modify | `TURN_ENABLED`, `TURN_LISTEN_PORT` (default `19403`), realm, server IP, accounting mode |
| `lib/diode.ex` | Modify | Start TURN subtree when enabled |
| `config/runtime.exs` or `config/config.exs` | Modify | `config :xturn, ...` merged from `Diode.Config`; **`:pipes`** with Diode `Authenticates` swapped in for `Xirsys.XTurn.Actions.Authenticates` |
| `docs/specs/tests-turn.yaml` | **Create** | Test vectors (see Phase 7) |
| `test/turn_*_test.exs` | **Create** | Unit/integration tests |

If **vendorizing xturn** (optional, for bandwidth only): add `vendor/xturn` or Git dependency with patches; document divergence in this spec’s Version history. **Do not** vendor xturn solely for authentication—use `:pipes` + Diode module.

## Output Structure

**Generates:**

- Public TURN listener on configured port(s) (UDP required for baseline; TCP/TLS optional per xturn config).
- `turnopen` on Edge and RPC returning credentials + endpoints for ICE.
- Credential store with 24h TTL and idempotent re-issue within TTL.
- Bandwidth accounting wired to `TicketStore.increase_device_usage/2`.

**Does not generate:**

- STUN-only public service without TURN allocate (unless explicitly desired later).
- Fleet contract changes beyond existing ticket byte accounting.
- Coturn or non-Elixir TURN servers.

## Type Conventions

| Type | Meaning | Examples |
|------|---------|----------|
| `device_address` | 20-byte Ethereum address (binary) | `<<0x12, ...>>` |
| `turn_credentials` | Map for clients | `%{"username" => ..., "credential" => ..., "ttl_seconds" => 86400, "urls" => [...], "realm" => ...}` |
| `expires_at` | Unix seconds | Same epoch as credential validity end |
| `bytes` | Non-negative integer | Relay + accounting policy per strategy |

**Normalization:** RPC may return host/port as JSON numbers/strings per existing `wireguard` patterns; ICE URLs should use host/port the client can reach (public `server_ip` / `HOST`).

## Error Handling

### Elixir

- Feature disabled: `{:error, :not_enabled}`
- Not authenticated: match Edge/RPC conventions (`401` / `-32000`)
- Internal xturn failure: `{:error, {:turn, reason}}`

### Per-command

| Command | Error | Response |
|---------|-------|----------|
| `turnopen` | No ticket | Same as `dio_wireguard_open` unauthenticated |
| `turnopen` | TURN disabled | 503 / structured error |
| `turnopen` | Store failure | 500 |

## Domain-Specific Sections

### Credential lifetime (24 hours)

- On first `turnopen` for a device: generate `username` / `password` (or derived secrets), store with `expires_at = now + 24h`.
- On subsequent `turnopen` before expiry: return **same** pair and same expiry (or remaining TTL in response).
- On expiry: delete row; next `turnopen` issues new credentials.
- The Diode pipeline authenticator (injected via `:pipes`) must validate MESSAGE-INTEGRITY using the same MD5-based long-term credential derivation as RFC 5766 / stock `Authenticates` (compatible with WebRTC).

### Bandwidth accounting strategy

Implementations MUST choose one and document it in code:

1. **Hooks-based (no xturn source changes):**  
   - Register `client_hooks` / `peer_hooks`.  
   - Maintain correlation from STUN `USERNAME` (or 5-tuple after first authenticated packet) to `device_address`.  
   - Sum `byte_size/1` per hook message according to agreed rules (include or exclude STUN overhead).  
   - Call `TicketStore.increase_device_usage/2` on deltas (debounce similarly to WireGuard if needed).

2. **Vendorized xturn:**  
   - Patch `Allocate.Client` (and/or add telemetry) to emit **per-allocation byte deltas** with **username** or stable allocation id mapped to device.  
   - Call `TicketStore.increase_device_usage/2` from that path; optionally keep hooks for debugging only.

**Rationale:** Product requirement “all bytes through relay addresses” aligns best with **internal counters** or **careful** hook filtering; hooks alone are easier to get wrong for billing.

## API Surface

### Edge: `["turnopen"]`

One-sentence description: Request TURN credentials for the authenticated device.

**Behavior:**

| Condition | Output |
|-----------|--------|
| Authenticated, first request in window | New credentials, TTL 24h |
| Authenticated, repeat within window | Same credentials, same expiry semantics |
| Not authenticated | Edge error `401` / bad input per existing patterns |
| TURN disabled | `503` or equivalent |

**Response payload:** JSON string or structured fields mirroring `WireGuardSessionInfo`-style convenience: `username`, `credential`, `urls` (list of TURN URIs), `realm`, `ttl_seconds`, optional `expires_at`.

### RPC: `dio_turn_open`

**Arguments:** `[]` (device from session), same as other ticketed local methods.

**Returns:** JSON object with credential fields suitable for `RTCPeerConnection` ICE servers configuration.

**Edge cases:** Session without device → `not authenticated`.

## Testing

See `docs/specs/tests-turn.yaml`. Implementations MAY add tests; spec cases MUST pass logically.

**Integration:** Mock or local xturn listener on ephemeral port in test; verify auth rejects unknown user; verify `TicketStore` increases when accounting path is triggered (may require hook test doubles if using strategy 1).

## Implementation Checklist

- [x] xturn stack resolves and starts under Diode supervision: in-tree `lib/xturn/` plus Hex `xmedialib` / `xturn_sockets` (no fork for auth)
- [x] Diode `Authenticates` module implements pipeline contract; `config :xturn, :pipes` replaces `Xirsys.XTurn.Actions.Authenticates` everywhere it appears in the pinned xturn defaults
- [x] `turnopen` / `dio_turn_open` implemented on Edge + RPC with ticket checks
- [x] 24h stable credentials and expiry behavior
- [x] Default port **19403** documented and configurable
- [x] Bandwidth strategy chosen (hooks vs vendor) and `TicketStore.increase_device_usage/2` called for relay traffic
- [x] `tests-turn.yaml` scenarios covered (unit tests under `test/diode/turn/`; run `mix test.turn`)
- [x] Version history updated

## Version history

| Version | Changes |
|---------|---------|
| v0.1.0 | Initial spec: Hex xturn embed, permissioned `turnopen`, 24h credentials, bandwidth via hooks or vendor patch; upstream review notes on `xturn_sockets` hooks and `Authenticates` limitations |
| v0.1.1 | **Primary approach:** Hex package only; **authentication** via new pipeline module + `config :xturn, :pipes` replacing `Xirsys.XTurn.Actions.Authenticates`; vendorizing reserved for optional bandwidth work |
| v0.1.2 | **Shipped:** In-tree **xturn 0.1.2** under `lib/xturn/` and **xmedialib 0.1.2** under `vendor/xmedialib/` (see `docs/vendoring-xturn.md`); Hex `xturn_sockets` / `xturn_cache`; `Diode.Turn.CredentialStore`, `Diode.Turn.Authenticates`, `Diode.Turn.AccountingHook`, `Diode.Turn.XturnDefaults`, `TurnService`; Edge `["turnopen"]`, RPC `dio_turn_open`; vendored `xmedialib` STUN uses `:crypto.mac/4` for OTP 28+. Accounting: client + peer hooks → `TicketStore.increase_device_usage/2` (see module docs). |
