# Diode Device Messaging Feature

## Overview

The Diode Device Messaging feature enables secure, traffic-accounted device-to-device communication within the Diode network. It allows edge devices to send arbitrary payload data to other devices, with metadata support for application-specific information.

**Integration context:** Extends the existing Network.EdgeV2 handler with new message routing capabilities and adds websocket JSON-RPC support via Network.Rpc and Network.RpcWs modules. Integrates with existing ticket-based authentication and traffic accounting systems.

## Design Principles

1. **Device-authenticated only.** Messages can only be sent by authenticated devices with valid tickets.
2. **Traffic-accounted.** All message traffic is tracked and billed according to device ticket allowances.
3. **Payload-agnostic.** Arbitrary binary payloads supported without content restrictions.
4. **Metadata-optional.** Flexible metadata system for application-specific routing and context.
5. **Same-node prioritized.** Local device routing preferred over network forwarding.
6. **Binary-safe encoding.** Base32 encoding for websocket transport ensures binary compatibility.

## Output Structure

This feature generates:

- **Network.EdgeV2** - Extended with message handling and routing logic
- **Network.Rpc** - Extended with `dio_message` and `dio_ticket` JSON-RPC methods
- **Network.RpcWs** - Extended to maintain per-connection device authentication state
- **test/network/edge_v2_message_e2e_test.exs** - End-to-end message delivery tests (see E2E Test Matrix: edge2/rpc × same/different nodes; dio_ticket positive test)

Does not generate:

- Standalone client libraries (integrates with existing DiodeClient)
- Message persistence or queuing systems
- Cross-chain message routing

## Type Conventions

| Type | Meaning | Examples |
|------|---------|----------|
| `device_address` | 20-byte Ethereum address | `0x1234567890123456789012345678901234567890` |
| `payload` | Arbitrary binary data | `<<1, 2, 3, 255>>`, `"hello world"` |
| `metadata` | Application-specific key-value map | `%{"type" => "chat", "priority" => 1}` |
| `ticket_data` | Signed device ticket in RLP format | Base32-encoded binary |
| `message_id` | Unique message identifier | Auto-generated UUID or timestamp |
| `error` | Standard RPC error response | `{"code": -32600, "message": "Invalid request"}` |

**Normalization:** Device addresses are normalized to lowercase hex format. Payloads and metadata are preserved as-is without transformation.

## Error Handling

### Per-Language Error Surface

**Elixir (Backend):**
- Invalid device addresses: `{:error, "invalid device id"}`
- Self-messaging attempts: `{:error, "can't connect to yourself"}`
- Missing authentication: `{:error, "device not authenticated"}`
- Traffic exceeded: `{:error, "insufficient ticket balance"}`
- Network unreachable: `{:error, "no nodes to forward message to"}`

### Per-Function Error Table

| Function/Method | Error Condition | Error Response |
|----------------|-----------------|---------------|
| `message/4` | Invalid destination address | `"invalid device id"` |
| `message/4` | Destination is self | `"can't connect to yourself"` |
| `dio_message` | No authenticated device | `{"code": -32000, "message": "not authenticated"}` |
| `dio_message` | Invalid destination format | `{"code": -32602, "message": "invalid params"}` |
| `dio_ticket` | Invalid ticket signature | `{"code": -32001, "message": "invalid ticket"}` |
| `dio_ticket` | Expired ticket | `{"code": -32002, "message": "ticket expired"}` |

## Domain-Specific Sections

### Traffic Accounting

Messages consume ticket bytes based on payload size:
- Base cost: 32 bytes per message
- Payload cost: `byte_size(payload)`
- Metadata cost: `byte_size(inspect(metadata))`

### Device Authentication

Websocket connections maintain device authentication state:
- Initial state: unauthenticated
- After `dio_ticket`: device_address stored in process dictionary
- Authentication persists for connection lifetime
- No cross-request authentication sharing

### Message Delivery Semantics

1. **Local delivery preferred:** Check PubSub for local device connection first
2. **Network forwarding:** Use candidate nodes from device ticket if local delivery fails
3. **At-most-once delivery:** No guaranteed delivery or retries
4. **No ordering guarantees:** Messages may arrive out-of-order

## API Surface

### message(destination, payload, metadata) → nil

Sends a message to another device via EdgeV2 binary protocol.

**Arguments:**
- `destination`: `device_address` - Target device Ethereum address
- `payload`: `payload` - Message content (binary)
- `metadata`: `metadata` - Optional application metadata (map)

**Behavior:**

| Condition | Output |
|-----------|--------|
| Valid destination, local device found | Message delivered to local process |
| Valid destination, no local device | Message forwarded via network |
| Invalid destination format | Error: "invalid device id" |
| Destination is self | Error: "can't connect to yourself" |

**Examples:**
```elixir
# Send chat message
Network.EdgeV2.message(target_device, "Hello!", %{"type" => "chat"})

# Send binary data
Network.EdgeV2.message(target_device, <<1, 2, 3, 255>>, %{})
```

### dio_message(destination, payload, metadata?) → null

Sends a message via websocket JSON-RPC interface.

**Arguments:**
- `destination`: `string` - Base16-encoded target device address
- `payload`: `string` - Base16-encoded message payload
- `metadata`: `object` - Optional metadata object (default: `{}`)

**Behavior:**

| Condition | Output |
|-----------|--------|
| Authenticated device, valid params | Message queued for delivery, returns `null` |
| Not authenticated | Error: -32000 "not authenticated" |
| Invalid destination format | Error: -32602 "invalid params" |
| Traffic limit exceeded | Error: -32003 "insufficient balance" |

**Examples:**
```json
// Send via websocket
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "dio_message",
  "params": [
    "1234567890123456789012345678901234567890",  // base16 device address
    "48656c6c6f20576f726c64",  // base16 "Hello World"
    {"type": "notification", "urgent": true}
  ]
}
```

**Response:**
```json
{"jsonrpc": "2.0", "id": 1, "result": null}
```

### dio_ticket(ticket_data) → null

Authenticates websocket connection with signed device ticket.

**Arguments:**
- `ticket_data`: `string` - Base16-encoded RLP ticket data

**Behavior:**

| Condition | Output |
|-----------|--------|
| Valid ticket signature | Stores device_address in connection state, returns `null` |
| Invalid signature | Error: -32001 "invalid ticket" |
| Expired ticket | Error: -32002 "ticket expired" |
| Already authenticated | Error: -32004 "already authenticated" |

**Examples:**
```json
// Authenticate connection
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "dio_ticket",
  "params": ["f8c8..."]  // base16-encoded ticket
}
```

**Response:**
```json
{"jsonrpc": "2.0", "id": 2, "result": null}
```

## Testing

### E2E Test Matrix

Message delivery can occur via two protocols (EdgeV2 binary, RPC websocket) and across one or two nodes. The full test matrix:

| # | Sender | Receiver | Nodes | Status |
|---|--------|----------|-------|--------|
| 1 | edge2 | edge2 | same node | ✅ Implemented |
| 2 | edge2 | edge2 | different nodes | ✅ Implemented |
| 3 | rpc | rpc | same node | ✅ Implemented |
| 4 | rpc | rpc | different nodes | ❌ Missing |
| 5 | edge2 | rpc | same node | ✅ Implemented |
| 6 | edge2 | rpc | different nodes | ❌ Missing |
| 7 | rpc | edge2 | same node | ✅ Implemented |
| 8 | rpc | edge2 | different nodes | ❌ Missing |

**Notes:**
- **edge2**: Device connected via EdgeV2 binary protocol (SSL)
- **rpc**: Device connected via websocket JSON-RPC (`/ws`), authenticated with `dio_ticket`
- **same node**: Both sender and receiver connect to the same Diode node
- **different nodes**: Sender and receiver connect to different Diode nodes (main + clone); requires network forwarding

### dio_ticket Positive Test (Prerequisite for RPC Messaging)

`dio_ticket` must be positively tested before RPC message delivery tests. The websocket handler must store the validated device address in its connection state for the session lifetime; only this enables `dio_message` to identify the sender.

**Required test:**
- Connect via websocket to RPC endpoint
- Call `dio_ticket` with valid, non-expired ticket
- Verify success response `{"jsonrpc":"2.0","id":N,"result":null}`
- Call `dio_message` with valid params — must succeed (not "not authenticated")
- Concludes: device id is correctly stored and persisted for the session

**Current gap:** The "websocket RPC methods validation" test only exercises invalid `dio_ticket` input. There is no positive test that verifies ticket validation and session-scoped device storage.

### Test Data Format (tests.yaml)

```yaml
message_delivery:
  - name: "local device message delivery"
    input:
      destination: "0x1234567890123456789012345678901234567890"
      payload: "SGVsbG8gV29ybGQ="  # base64 "Hello World"
      metadata: {"type": "test"}
    output: null
    authenticated: true

  - name: "websocket message delivery"
    method: "dio_message"
    params:
      - "ABCDEFGHJKLMNPQRSTUVWXYZ234567"  # base32 device address
      - "ABCDEFGHJKLMNPQRSTUVWXYZ234567"  # base32 payload
      - {"type": "websocket_test"}
    output: null
    authenticated: true

ticket_authentication:
  - name: "valid ticket authentication"
    method: "dio_ticket"
    params: ["ABCDEFGHJKLMNPQRSTUVWXYZ234567..."]
    output: null
    expect_device: "0x1234567890123456789012345678901234567890"
```

### Test Generation

**Elixir Unit Tests:**
```elixir
test "local device message delivery" do
  # Test EdgeV2.message/3 directly
end

test "websocket message delivery" do
  # Test Network.Rpc.execute_dio with dio_message
end
```

**E2E Integration Tests (test/network/edge_v2_message_e2e_test.exs):**
```elixir
# Existing
test "message delivery between devices on same node" do  # edge2 -> edge2, same node
  ...
end

# Missing - to be added
test "message delivery edge2 -> edge2 on different nodes"
test "message delivery rpc -> rpc on same node"
test "message delivery rpc -> rpc on different nodes"
test "message delivery edge2 -> rpc on same node"
test "message delivery edge2 -> rpc on different nodes"
test "message delivery rpc -> edge2 on same node"
test "message delivery rpc -> edge2 on different nodes"
test "dio_ticket authenticates session and enables dio_message"  # positive auth flow
```

## Generated Documentation

### Integration Documentation (docs/features/messaging.md)

#### Setup

1. Ensure device has valid ticket with sufficient balance
2. For websocket: Call `dio_ticket` to authenticate connection
3. Send messages using preferred interface

#### Usage Examples

**Binary Protocol (EdgeV2):**
```elixir
# Direct device-to-device messaging
Network.EdgeV2.message(target_device, payload, metadata)
```

**Websocket JSON-RPC:**
```javascript
// Authenticate
ws.send(JSON.stringify({
  jsonrpc: "2.0",
  id: 1,
  method: "dio_ticket",
  params: [base32Ticket]
}));

// Send message
ws.send(JSON.stringify({
  jsonrpc: "2.0",
  id: 2,
  method: "dio_message",
  params: [base32Destination, base32Payload, metadata]
}));
```

#### Error Handling

- Check ticket balance before sending large messages
- Handle authentication timeouts (re-authenticate with `dio_ticket`)
- Expect network delays for cross-node messages

#### Traffic Costs

Messages consume ticket bytes based on:
- Fixed overhead: 32 bytes
- Payload size: `payload.length`
- Metadata size: JSON serialization size

## Implementation Checklist

- [x] EdgeV2 message routing implemented
- [x] Local device delivery working
- [x] Network forwarding logic added
- [x] Traffic accounting integrated
- [x] Websocket JSON-RPC `dio_message` method
- [x] Base16 encoding/decoding for binaries (base32 not available)
- [x] `dio_ticket` authentication method
- [x] Per-connection device state storage (see note below)
- [x] End-to-end delivery test: edge2 → edge2 same node
- [x] Error handling for all edge cases
- [x] Documentation generated
- [x] **dio_ticket positive test** — websocket session stores device id, enabling dio_message
- [x] **E2E test: edge2 → edge2 different nodes**
- [x] **E2E test: rpc → rpc same node**
- [ ] **E2E test: rpc → rpc different nodes**
- [x] **E2E test: edge2 → rpc same node**
- [ ] **E2E test: edge2 → rpc different nodes**
- [x] **E2E test: rpc → edge2 same node**
- [ ] **E2E test: rpc → edge2 different nodes**
- [ ] Integration with existing client libraries
- [ ] Performance testing under load

**Note on per-connection device state:** Resolved in v0.4 — for `dio_ticket` and `dio_message`, RpcWs now runs handlers synchronously in the websocket process (no spawn), so `Process.put({:websocket_device, self()})` persists correctly across requests.

## Version History

- **v0.1** - Initial implementation with local delivery only
- **v0.2** - Added network forwarding and websocket support
- **v0.3** - Added `dio_ticket` authentication and traffic accounting
- **v0.4** - Documented full E2E test matrix (8 scenarios), dio_ticket positive test requirement, and RpcWs state persistence note