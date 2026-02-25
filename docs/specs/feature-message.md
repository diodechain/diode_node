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
6. **Binary-safe encoding.** Binary payloads are hex-encoded (Base16, 0x prefix) when delivered over the websocket RPC interface so JavaScript clients can receive and decode them.

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
| `ticket_data` | Signed device ticket in RLP format (RPC) | Hex string with 0x prefix |
| `message_id` | Unique message identifier | Auto-generated UUID or timestamp |
| `error` | Standard RPC error response | `{"code": -32600, "message": "Invalid request"}` |

**Hex encoding:** All hex-encoded strings in the RPC API (destination, payload, ticket_data, and binary fields in notifications) use a **0x prefix** (e.g. `"0x48656c6c6f"`).

**Normalization:** Device addresses are normalized to lowercase hex format. Payloads and metadata are preserved as-is on the EdgeV2 (binary) path. When a message is delivered to an RPC (websocket) subscriber, the payload and any binary metadata values are encoded as hex (0x-prefixed) in the JSON notification so that JavaScript clients can safely receive and decode binary data (see *Encoding for RPC (JavaScript) delivery* below).

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

### Encoding for RPC (JavaScript) delivery

When a message is delivered to a subscriber connected via **websocket JSON-RPC** (e.g. a browser or Node.js client), the receiver cannot handle raw binary in JSON. Therefore:

- **Payload:** The raw binary payload is **always hex-encoded (Base16) with a 0x prefix** in the `dio_message_received` notification. The `params.payload` field is a string starting with `0x` followed by hex digits (e.g. `"0x48656c6c6f"` for the bytes `Hello`). JavaScript clients must decode this string (e.g. `Buffer.from(payload.replace(/^0x/, ''), 'hex')`) to obtain the original bytes.
- **Metadata:** Any metadata value that is binary must also be hex-encoded (0x-prefixed) when present in the notification so that the JSON payload is valid and the client can decode it. String and numeric metadata values are passed through as-is.

This applies regardless of how the message was sent (EdgeV2 binary or `dio_message` RPC): delivery to an RPC/websocket subscriber always uses hex for binary data so that JavaScript consumers receive a consistent, safe encoding.

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
- `destination`: `string` - Hex-encoded target device address (0x-prefixed)
- `payload`: `string` - Hex-encoded message payload (0x-prefixed)
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
    "0x1234567890123456789012345678901234567890",  // device address
    "0x48656c6c6f20576f726c64",  // "Hello World"
    {"type": "notification", "urgent": true}
  ]
}
```

**Response:**
```json
{"jsonrpc": "2.0", "id": 1, "result": null}
```

### dio_message_received (notification)

When a message is delivered to a device that is connected via websocket RPC, the server pushes a JSON-RPC notification (no `id`). The payload is **always hex-encoded with a 0x prefix** so that JavaScript clients can receive arbitrary binary data safely:

```json
{
  "jsonrpc": "2.0",
  "method": "dio_message_received",
  "params": {
    "payload": "0x48656c6c6f20576f726c64",
    "metadata": {"type": "chat"}
  }
}
```

- **payload:** Hex string (0x-prefixed) of the raw message bytes. In JavaScript decode with e.g. `Buffer.from(params.payload.replace(/^0x/, ''), 'hex')`.
- **metadata:** Application metadata; any binary values in metadata are hex-encoded (0x-prefixed) when sent over RPC.

This encoding applies whether the message was sent via EdgeV2 (binary) or via `dio_message` (RPC); delivery to an RPC subscriber always uses hex for binary content.

### dio_ticket(ticket_data) → null

Authenticates websocket connection with signed device ticket.

**Arguments:**
- `ticket_data`: `string` - Hex-encoded RLP ticket data (0x-prefixed)

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
  "params": ["0xf8c8..."]  // hex-encoded ticket (0x-prefixed)
}
```

**Response:**
```json
{"jsonrpc": "2.0", "id": 2, "result": null}
```

## Testing

### E2E Test Matrix

Message delivery can occur via two protocols (EdgeV2 binary, RPC websocket) and across one or two nodes. The full test matrix:

| # | Sender | Receiver | Nodes |
|---|--------|----------|-------|
| 1 | edge2 | edge2 | same node |
| 2 | edge2 | edge2 | different nodes |
| 3 | rpc | rpc | same node |
| 4 | rpc | rpc | different nodes |
| 5 | edge2 | rpc | same node |
| 6 | edge2 | rpc | different nodes |
| 7 | rpc | edge2 | same node |
| 8 | rpc | edge2 | different nodes |

- **edge2:** Device connected via EdgeV2 binary protocol (SSL).
- **rpc:** Device connected via websocket JSON-RPC (`/ws`), authenticated with `dio_ticket`.
- **same node:** Both sender and receiver connect to the same Diode node.
- **different nodes:** Sender and receiver on different nodes; requires network forwarding.


### dio_ticket positive test (prerequisite for RPC messaging)

The websocket handler must store the validated device address in its connection state for the session lifetime so that `dio_message` can identify the sender. A positive test must: connect via websocket, call `dio_ticket` with a valid non-expired ticket, verify success, then call `dio_message` and confirm it succeeds (not "not authenticated").

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
      - "0x303132333435363738393031323334353637383930"  # device address
      - "0x48656c6c6f20576f726c64"  # "Hello World"
      - {"type": "websocket_test"}
    output: null
    authenticated: true

ticket_authentication:
  - name: "valid ticket authentication"
    method: "dio_ticket"
    params: ["0xf8c8..."]  # hex-encoded RLP ticket (0x-prefixed)
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

**E2E integration tests** cover all eight matrix cases (edge2/rpc × same/different nodes) in `test/network/edge_v2_message_e2e_test.exs`, plus a positive `dio_ticket` flow that confirms session-scoped device storage.

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
// Authenticate (ticket is hex string with 0x prefix)
ws.send(JSON.stringify({
  jsonrpc: "2.0",
  id: 1,
  method: "dio_ticket",
  params: [ticketHex]  // e.g. "0xf8c8..."
}));

// Send message (destination and payload are hex strings with 0x prefix)
ws.send(JSON.stringify({
  jsonrpc: "2.0",
  id: 2,
  method: "dio_message",
  params: [destinationHex, payloadHex, metadata]
}));

// On dio_message_received: params.payload is 0x-prefixed hex; decode in JS e.g. Buffer.from(payload.replace(/^0x/, ''), 'hex')
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

## Version History

- **v0.1** - Initial implementation with local delivery only
- **v0.2** - Network forwarding and websocket support
- **v0.3** - `dio_ticket` authentication and traffic accounting
- **v0.4** - Full E2E test matrix (8 scenarios), RPC delivery encoding (hex for JS)
- **v0.5** - Spec cleanup: removed migration/status content; added encoding rules for EdgeV2→RPC (hex) delivery