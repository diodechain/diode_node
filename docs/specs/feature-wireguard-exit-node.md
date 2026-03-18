# WireGuard Exit Node Service Specification v0.1.3

**Spec type:** Feature  
**Path:** `docs/specs/feature-wireguard-exit-node.md`

## Overview

The WireGuard Exit Node service runs a local WireGuard interface as an "exit node" that allows authenticated Diode devices to tunnel traffic through the node to the public internet. The service listens on a public UDP port and, by default, has no peers configured. Devices add themselves by submitting their WireGuard public key via Edge or websocket RPC. Traffic is polled per-peer and accounted via `TicketStore.increase_device_usage/2`, driving the existing ticket-based billing flow.

**Integration context:** Extends `Network.EdgeV2` with `["wireguard", "open"|"close", ...]` handling, extends `Network.Rpc` for websocket wireguard commands (connection-state path), integrates with `TicketStore`, and introduces a new `WireGuardService` GenServer backed by the [wireguardex](https://github.com/firezone/wireguardex) package. Requires `wireguardex` dependency. **Primary deployment:** Canonical snap. **Privileges:** Creating network interfaces requires the `network-control` snap plug (grants CAP_NET_ADMIN); see [Snap Deployment](#snap-deployment) below.

## Design Principles

1. **Device-authenticated only.** Only authenticated devices (Edge SSL identity or websocket `dio_ticket`) can add or remove wireguard peers.
2. **One public key per device.** A second `["wireguard", "open", ...]` replaces the previous key (remove old, add new).
3. **Traffic-accounted.** Traffic is polled per-peer every minute and passed to `TicketStore.increase_device_usage/2`; on close, remaining traffic is accounted immediately.
4. **No peer-to-peer.** Multiple devices on the same node cannot reach each other; each peer has an isolated tunnel IP.
5. **Public internet only.** The node's local network (RFC1918 ranges) is not exposed to devices; only public internet egress is allowed.

## Files to Modify or Create

| File | Action | Purpose |
|------|--------|---------|
| `mix.exs` | Modify | Add `{:wireguardex, "~> 0.5"}` to deps |
| `lib/wire_guard_service.ex` | **Create** | WireGuardService GenServer |
| `lib/network/edge_v2.ex` | Modify | Add `["wireguard", "open"|"close", ...]` clauses in `do_handle_async_msg` |
| `lib/network/rpc.ex` | Modify | Add `dio_wireguard_open`, `dio_wireguard_close` in `execute_dio`; add to `@local_dio_methods` |
| `lib/network/rpc_ws.ex` | Modify | Add `dio_wireguard_open`, `dio_wireguard_close` to `needs_connection_state?/1` |
| `lib/config.ex` | Modify | Add `WIREGUARD_*` to `defaults()` (or handle nil in callers; `Diode.Config.get/1` returns nil if unset) |
| `lib/diode.ex` | Modify | Conditionally add `WireGuardService` to children when enabled |
| `snap/snapcraft.yaml` | Modify | Add `network-control` to service app plugs |
| `test/wire_guard_service_test.exs` | **Create** | Unit tests |
| `test/network/wireguard_*.exs` | **Create** | Integration tests (optional) |
| `docs/features/wireguard-exit-node.md` | **Create** | Integration docs (optional) |

## Output Structure

**Generates:**
- `WireGuardService` – GenServer managing the WireGuard interface and peer lifecycle
- `Network.EdgeV2` – Extended with `["wireguard", "open"|"close", ...]` handling
- `Network.Rpc` / `Network.RpcWs` – Wireguard commands via websocket (connection-state path)
- `Diode` application – `WireGuardService` in supervision tree (when configured)
- Configuration options for interface name, listen port, tunnel subnet
- Tests for open/close, key replacement, traffic accounting, isolation

**Does not generate:**
- WireGuard client software
- Fleet/contract changes for wireguard-specific billing
- Multi-interface or multi-node wireguard coordination

## Type Conventions

| Type | Meaning | Examples |
|------|---------|----------|
| `device_address` | 20-byte Ethereum address (binary) | `<<0x12, ...>>` |
| `public_key` | WireGuard public key, 32 bytes | Base64 or binary per wireguardex |
| `interface_name` | WireGuard interface name | `"wg0"`, `"diode_wg"` |
| `bytes` | Non-negative integer | Traffic count in bytes |
| `error` | Elixir `{:error, term()}` or RPC error object | `{:error, :already_started}` |

**Public key encoding by transport:**
- **Edge (binary protocol):** The public key is sent as **raw binary** (32 bytes) in the RLP-encoded message.
- **Websocket RPC:** The public key is sent as **`DiodeClient.Base16`-encoded string** (hex, 0x-prefix optional per project convention). Implementations MUST decode with `Base16.decode/1` before passing to `WireGuardService.add_peer/2`.

**Normalization:** wireguardex expects Base64-encoded WireGuard public keys. After decoding from transport (binary or Base16), implementations MUST convert the 32-byte binary to Base64 for `Wireguardex.add_peer/2` and `Wireguardex.remove_peer/2`.

## Error Handling

### Elixir Error Surface

- WireGuard interface already running: `{:error, :already_started}`
- Invalid public key format: `{:error, :invalid_public_key}`
- wireguardex/OS failure: `{:error, {:wireguard, reason}}`
- Device not authenticated (RPC): JSON-RPC `-32000 "not authenticated"`
- Bad params: JSON-RPC `-32602 "invalid params"`

### Per-Function Error Table

| Function/Command | Error Condition | Error Response |
|------------------|-----------------|----------------|
| `open/2` | Invalid public key | `{:error, :invalid_public_key}` |
| `open/2` | wireguardex failure | `{:error, {:wireguard, reason}}` |
| `close/1` | Device not in config | `:ok` (idempotent) |
| `["wireguard", "open", _]` (Edge) | Not authenticated | `["error", 401, "bad input"]` |
| `dio_wireguard_open` / Edge via WS | No `dio_ticket` | `{"code": -32000, "message": "not authenticated"}` |

## Domain-Specific Sections

### Peer-to-Peer Isolation

Each device receives a unique tunnel IP from a configured subnet (e.g. `10.0.0.0/24`). In wireguardex, the peer's `allowed_ips` (via `PeerConfigBuilder`) specifies which source IPs we accept from that peer. Set to the peer's tunnel IP only (e.g. `["10.0.0.2/32"]`) so:

- The peer sends traffic from its assigned IP.
- No route is advertised to other peers for that IP.
- Only traffic destined for the public internet (excluding RFC1918) is forwarded; local LAN is not reachable.

**Rationale:** Prevents devices from probing or attacking each other or the host network.

### Traffic Polling

- Poll interval: 60 seconds (configurable).
- On each tick: for each peer, read `rx_bytes` + `tx_bytes` from wireguardex device stats, compute delta since last poll, call `TicketStore.increase_device_usage(device_address, delta)`.
- On peer removal: account any traffic since last poll immediately, then remove peer.

### Key Replacement

When a device calls `["wireguard", "open", new_public_key]` and already has a peer:

1. Remove existing peer (by old public key) from WireGuard config.
2. Account traffic for that peer immediately.
3. Add new peer with `new_public_key`, same device mapping.
4. Assign same tunnel IP (or new IP from pool); device identity is preserved.

## API Surface

### WireGuardService (GenServer)

#### `add_peer(device_address, public_key) → :ok | {:error, term()}`

Adds or replaces a peer for the given device. If the device already has a peer, the old peer is removed and traffic accounted before adding the new one.

**Arguments:**
- `device_address`: 20-byte binary (Ethereum address)
- `public_key`: WireGuard public key (format per wireguardex)

**Behavior:**

| Condition | Output |
|-----------|--------|
| New device | Add peer, assign tunnel IP, return `:ok` |
| Existing device | Remove old peer, account traffic, add new peer, return `:ok` |
| Invalid public key | `{:error, :invalid_public_key}` |
| wireguardex failure | `{:error, {:wireguard, reason}}` |

#### `remove_peer(device_address) → :ok`

Removes the peer for the device. Traffic is accounted immediately before removal. Idempotent if device has no peer.

**Arguments:**
- `device_address`: 20-byte binary

**Behavior:**

| Condition | Output |
|-----------|--------|
| Device has peer | Account traffic, remove peer, return `:ok` |
| Device has no peer | Return `:ok` |

### Edge Async Messages

#### `["wireguard", "open", public_key]` → `["response", "ok"]` | `["error", ...]`

Adds or replaces the WireGuard peer for the authenticated Edge device. **Encoding:** `public_key` is raw binary (32 bytes) in the Edge RLP message.

**Behavior:** Use `Network.EdgeV2.response/1` and `Network.EdgeV2.error/2` for consistency:

| Condition | Output |
|-----------|--------|
| Authenticated, valid key | `response("ok")` → `["response", "ok"]` |
| Invalid key | `error(400, "invalid public key")` → `["error", 400, "invalid public key"]` |
| wireguardex failure | `error(500, "wireguard error")` → `["error", 500, "wireguard error"]` |
| WireGuard disabled | `error(503, "wireguard not enabled")` |

#### `["wireguard", "close"]` → `["response", "ok"]`

Removes the WireGuard peer for the authenticated Edge device. Traffic is accounted immediately.

**Behavior:**

| Condition | Output |
|-----------|--------|
| Authenticated | `["response", "ok"]` (idempotent) |

### Websocket RPC

Use **dedicated RPC methods** `dio_wireguard_open` and `dio_wireguard_close` (same pattern as `dio_ticket`, `dio_message`). Add both to `needs_connection_state?/1` in `Network.RpcWs` so they run in the websocket process with `Process.get({:websocket_device, self()})`. Add both to `@local_dio_methods` in `Network.Rpc` so `RemoteChain.Edge.do_rpc/3` routes them locally. Require prior `dio_ticket`; return `%{"code" => -32000, "message" => "not authenticated"}` when `Process.get({:websocket_device, self()}) == nil`.

#### `dio_wireguard_open(public_key) → null`

Adds or replaces the WireGuard peer for the websocket-authenticated device.

**Arguments:**
- `public_key`: `DiodeClient.Base16`-encoded string (hex) of the 32-byte WireGuard public key. Decode with `Base16.decode/1` before passing to WireGuardService.

**Examples:**
```json
{"jsonrpc":"2.0","id":1,"method":"dio_wireguard_open","params":["0x1234..."]}
```

**Response:** `{"jsonrpc":"2.0","id":1,"result":null}`

#### `dio_wireguard_close() → null`

Removes the WireGuard peer for the websocket-authenticated device.

**Examples:**
```json
{"jsonrpc":"2.0","id":2,"method":"dio_wireguard_close","params":[]}
```

**Response:** `{"jsonrpc":"2.0","id":2,"result":null}`

**RPC error handling:** Use `result(nil, 400, %{"code" => code, "message" => msg})` per `Network.Rpc` conventions. Example: `result(nil, 400, %{"code" => -32000, "message" => "not authenticated"})`.

## Configuration

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `WIREGUARD_INTERFACE` | string | `"diode_wg"` | WireGuard interface name |
| `WIREGUARD_LISTEN_PORT` | integer | (required) | UDP port for WireGuard (public) |
| `WIREGUARD_TUNNEL_SUBNET` | string | `"10.0.0.0/24"` | Subnet for peer tunnel IPs |
| `WIREGUARD_POLL_INTERVAL_MS` | integer | `"60000"` | Traffic poll interval (ms) |
| `WIREGUARD_ENABLED` | string | `"0"` | `"1"` to enable; WireGuardService not started when falsy |

**Config convention:** Use `Diode.Config.get("WIREGUARD_ENABLED")` etc., consistent with `RPC_PORT`, `EDGE2_PORT`. Snap: `snapctl get wireguard-enabled` (lowercase, hyphenated).

**Deployment requirements:** The process must run as root or have `CAP_NET_ADMIN` (wireguardex creates network interfaces). For snap deployment, use the `network-control` plug; see [Snap Deployment](#snap-deployment). Tests require Rust for NIF compilation and interface-create privileges.

### Snap Deployment

The node is primarily deployed via Canonical's snap. The [network-control](https://snapcraft.io/docs/reference/interfaces#interfaces-network-control-interface) interface grants low-level network access (including CAP_NET_ADMIN), required for wireguardex to create WireGuard interfaces. It does **not** auto-connect.

**snapcraft.yaml:** Add `network-control` to the plugs of the `service` app. Snap name is `diode-node`:

```yaml
apps:
  service:
    command: bin/run start
    plugs: [network, network-bind, network-control]
```

The interface is not granted until the user runs `snap connect`; the service will only create WireGuard interfaces when `wireguard_enabled` is true.

**Post-install (manual connect):** After installing the snap, the user must connect the interface (snap name: `diode-node`):

```bash
sudo snap connect diode-node:network-control
```

Then restart the service if it was already running:

```bash
sudo snap restart diode-node.service
```

**If firewall-control is needed** (e.g. for iptables rules to exclude local network from device access):

```bash
sudo snap connect diode-node:firewall-control
```

Add `firewall-control` to the plugs in snapcraft.yaml if the implementation uses it for local-network exclusion.

## Testing

### Unit Tests (WireGuardService)

- `add_peer` with new device → peer added, returns `:ok`
- `add_peer` with existing device → old peer replaced, traffic accounted
- `remove_peer` with peer → traffic accounted, peer removed
- `remove_peer` without peer → `:ok` (idempotent)
- Poll tick → `TicketStore.increase_device_usage` called with correct delta

### Integration Tests

- Edge: connect, send `["wireguard","open",key]`, verify peer in config; send `["wireguard","close"]`, verify removal
- RPC: `dio_ticket`, `dio_wireguard_open`, `dio_wireguard_close`; verify not authenticated error without ticket
- Two devices: both open, verify neither can reach the other's tunnel IP
- Local network: verify devices cannot reach node LAN

### Test Data Format

Tests are defined in `docs/specs/tests-wireguard.yaml`. See that file for full cases.

**Input field mapping:**
- `wireguard_add_peer` / `wireguard_remove_peer`: `input.device` (hex), `input.public_key` (hex for WS, raw binary for Edge)
- `edge_wireguard_open`: `method_params` = `["wireguard", "open"|"close", public_key?]` — public_key is raw binary
- `rpc_wireguard`: `method`, `params`, `authenticated`

```yaml
# Example structure (tests-wireguard.yaml)
wireguard_open:
  - name: "open new peer"
    input: {device: "0x1234...", public_key: "BASE64KEY"}
    output: :ok

  - name: "open replaces existing"
    input: {device: "0x1234...", public_key: "NEW_BASE64KEY"}
    output: :ok
    setup: {device: "0x1234...", public_key: "OLD_BASE64KEY"}

wireguard_close:
  - name: "close with peer"
    input: {device: "0x1234..."}
    output: :ok

  - name: "close without peer (idempotent)"
    input: {device: "0x9999..."}
    output: :ok
```

## Implementation Checklist

- [ ] Add `{:wireguardex, "~> 0.5"}` to `mix.exs` deps
- [ ] Create `WireGuardService` GenServer
- [ ] WireGuard interface setup (create, listen port, private key)
- [ ] `add_peer` / `remove_peer` with key replacement logic
- [ ] Per-peer traffic polling → `TicketStore.increase_device_usage`
- [ ] Immediate traffic accounting on remove
- [ ] Peer isolation (AllowedIPs per peer, no cross-peer routes)
- [ ] Local network exclusion (firewall or routing)
- [ ] EdgeV2: add `["wireguard", "open", public_key]` and `["wireguard", "close"]` clauses in `do_handle_async_msg` (before the `_` catch-all); guard that `wireguard_enabled?` or return `error(503, "wireguard not enabled")`
- [ ] RPC: `dio_wireguard_open` / `dio_wireguard_close` in `execute_dio`; add to `needs_connection_state?` and `@local_dio_methods`
- [ ] `wireguard_enabled` and config wiring in `Diode` application
- [ ] Snap: add `network-control` plug to `snap/snapcraft.yaml` for the service app; document `snap connect diode-node:network-control` in setup docs
- [ ] Unit and integration tests
- [ ] Documentation (integration notes)

## Generated Documentation

### Integration (docs/features/wireguard-exit-node.md)

#### Setup

1. Add `{:wireguardex, "~> 0.5"}` to `mix.exs` deps
2. Set `WIREGUARD_ENABLED=1`, `WIREGUARD_LISTEN_PORT`, and optional `WIREGUARD_INTERFACE` (env or `snapctl set diode-node wireguard-enabled=true`)
3. Ensure WireGuard kernel module is loaded (Linux: `modprobe wireguard`)
4. **Privileges (snap):** `sudo snap connect diode-node:network-control` then `sudo snap restart diode-node.service`. See [Snap Deployment](#snap-deployment) in the spec. **Non-snap:** Run as root, or `sudo setcap 'cap_net_admin+eip' $(which beam.smp)` (see [wireguardex](https://github.com/firezone/wireguardex#note-about-privileges)).
5. Optionally force NIF compilation: `config :rustler_precompiled, :force_build, wireguardex: true` or `WIREGUARDNIF_BUILD=true`
6. `WireGuardService` is started by `Diode` when enabled

#### Usage

**Edge (binary):** Device connects via SSL, then sends RLP-encoded `[request_id, ["wireguard", "open", public_key], opts]` or `[request_id, ["wireguard", "close"], opts]`. The `public_key` is **raw binary** (32 bytes).

**Websocket RPC:**
```javascript
// 1. Authenticate
ws.send(JSON.stringify({jsonrpc:"2.0", id:1, method:"dio_ticket", params:[ticketHex]}));
// 2. Open wireguard peer (public_key: Base16/hex string)
ws.send(JSON.stringify({jsonrpc:"2.0", id:2, method:"dio_wireguard_open", params:[hexPublicKey]}));
// 3. Close wireguard peer
ws.send(JSON.stringify({jsonrpc:"2.0", id:3, method:"dio_wireguard_close", params:[]}));
```

#### wireguardex API Reference

The [wireguardex](https://github.com/firezone/wireguardex) package (module name `Wireguardex`, not `WireGuardEx`) provides:

**Device setup (builder pattern):**
- `import Wireguardex.DeviceConfigBuilder` and `import Wireguardex, only: [set_device: 2]`
- `device_config() |> private_key(...) |> listen_port(...) |> set_device(interface_name)` – creates the interface
- `Wireguardex.generate_private_key()` – generate server private key
- `Wireguardex.get_public_key(private_key)` → `{:ok, public_key}`

**Peer management:**
- `import Wireguardex.PeerConfigBuilder`
- `peer_config() |> public_key(...) |> allowed_ips([ip/cidr]) |> ...` – build peer; `allowed_ips` is a list, e.g. `["10.0.0.2/32"]`
- `Wireguardex.add_peer(interface_name, peer)` – add peer to existing device
- `Wireguardex.remove_peer(interface_name, public_key)` – remove peer by public key
- `Wireguardex.get_device(interface_name)` → `{:ok, device}` – get device info (peers, stats)
- `Wireguardex.delete_device(interface_name)` – tear down interface

**Optional peer fields:** `preshared_key`, `endpoint`, `persistent_keepalive_interval` – omit for exit-node peers if not needed.

## Version History

- **v0.1.0** – Initial specification
- **v0.1.1** – Snap deployment: `network-control` plug and `snap connect diode-node:network-control`
- **v0.1.2** – Public key encoding: Edge uses raw binary; websocket RPC uses `DiodeClient.Base16` (hex)
- **v0.1.3** – Align with project practice: files-impact table, dedicated RPC methods, `Diode.Config` keys, `response`/`error`/`result` usage, `@local_dio_methods`, `needs_connection_state`
