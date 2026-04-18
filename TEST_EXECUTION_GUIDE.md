# WireGuard Exit Node - Test Execution Guide

## Prerequisites

1. **Elixir/OTP 25+** installed
2. **Rust toolchain** (for wireguardex NIF compilation)
3. **WireGuard kernel module** loaded (`modprobe wireguard`)
4. **CAP_NET_ADMIN** capability or root access (for interface creation)
5. **snapcraft** (for snap build testing)

## Test Execution Steps

### 1. Install Dependencies

```bash
mix deps.get
```

This will fetch `wireguardex` and compile its Rust NIFs. This may take a few minutes.

### 2. Compile the Project

```bash
mix compile
```

Verify no compilation errors. The wireguardex NIF compilation requires Rust.

### 3. Run Linting

```bash
mix lint
```

This runs:
- `mix compile` (with warnings as errors)
- `mix format --check-formatted`
- `mix credo --only warning`
- `mix dialyzer`

### 4. Run Unit Tests

#### WireGuardService Tests

```bash
# Run all WireGuardService tests (will skip if WireGuard not enabled)
mix test test/wire_guard_service_test.exs

# Run with WireGuard enabled
WIREGUARD_ENABLED=1 mix test test/wire_guard_service_test.exs

# Run only wireguard-tagged tests
mix test --tag wireguard
```

**Expected behavior:**
- Tests marked with `@tag :skip` will be skipped
- If WireGuard is not enabled or interface creation fails, tests should gracefully skip
- Tests that don't require a live interface (e.g., key validation) should run

#### Full Test Suite

```bash
# Run all tests to ensure no regressions
mix test

# Exclude wireguard tests if not available
mix test --exclude wireguard
```

### 5. Integration Tests (Manual)

#### Edge Integration Test

1. Start the node with WireGuard enabled:
   ```bash
   WIREGUARD_ENABLED=1 WIREGUARD_LISTEN_PORT=51820 mix run --no-halt
   ```

2. Connect via Edge protocol and send:
   ```
   ["wireguard", "open", <32-byte-public-key-binary>]
   ```
   Expected: `["response", "ok"]`

3. Send:
   ```
   ["wireguard", "close"]
   ```
   Expected: `["response", "ok"]`

#### RPC Integration Test

1. Connect via WebSocket RPC
2. Authenticate with `dio_ticket`
3. Call `dio_wireguard_open` with hex-encoded public key:
   ```json
   {"jsonrpc":"2.0","id":1,"method":"dio_wireguard_open","params":["0x1234..."]}
   ```
   Expected: `{"jsonrpc":"2.0","id":1,"result":null}`

4. Call `dio_wireguard_close`:
   ```json
   {"jsonrpc":"2.0","id":2,"method":"dio_wireguard_close","params":[]}
   ```
   Expected: `{"jsonrpc":"2.0","id":2,"result":null}`

5. Test without authentication (should fail):
   ```json
   {"jsonrpc":"2.0","id":3,"method":"dio_wireguard_open","params":["0x1234..."]}
   ```
   Expected: `{"jsonrpc":"2.0","id":3,"error":{"code":-32000,"message":"not authenticated"}}`

### 6. Traffic Accounting Verification

1. Add a peer via Edge or RPC
2. Generate some traffic through the WireGuard interface
3. Wait for polling interval (60s) or remove peer
4. Check traffic accounting:
   ```elixir
   # In IEx console
   device_address = <<...>> # Your device address
   TicketStore.device_usage(device_address)
   ```

### 7. Snap Build Test

#### Build the Snap

```bash
cd /workspace
snapcraft
```

This will:
1. Build the Elixir application
2. Package it as a snap
3. Include the `network-control` and `firewall-control` plugs in the service app (plus staged `iptables` / `iproute2` for NAT)

#### Verify Snap Configuration

```bash
# Check the built snap
snap info diode-node_*.snap

# Install (requires sudo)
sudo snap install diode-node_*.snap --dangerous

# Verify plugs are listed
snap connections diode-node | grep -E 'network-control|firewall-control'

# Connect interfaces (WireGuard + NAT for peer internet egress)
sudo snap connect diode-node:network-control
sudo snap connect diode-node:firewall-control

# Start the service
sudo snap start diode-node.service

# Check service status
sudo snap services diode-node
```

#### Test WireGuard in Snap

1. Enable WireGuard:
   ```bash
   sudo snap set diode-node wireguard-enabled=true
   sudo snap set diode-node wireguard-listen-port=51820
   sudo snap restart diode-node.service
   ```

2. Verify interface was created:
   ```bash
   ip link show diode_wg
   ```

3. Test peer addition via Edge or RPC (as above)

## Validation Checklist

- [ ] `mix compile` succeeds
- [ ] `mix lint` passes
- [ ] Unit tests pass (or skip gracefully when WireGuard unavailable)
- [ ] Edge wireguard commands work
- [ ] RPC wireguard commands work
- [ ] Authentication required for RPC commands
- [ ] Traffic accounting works (polling and immediate)
- [ ] Peer replacement works (new key replaces old)
- [ ] Snap builds successfully
- [ ] Snap includes `network-control` and `firewall-control` plugs
- [ ] Snap service starts with WireGuard enabled

## Known Limitations

1. **Tests require CAP_NET_ADMIN**: WireGuard interface creation requires elevated privileges
2. **Rust dependency**: wireguardex NIF compilation requires Rust toolchain
3. **Kernel module**: WireGuard kernel module must be loaded
4. **Snap interfaces**: `network-control` and `firewall-control` must be manually connected after installation (for WireGuard + automatic NAT)

## Troubleshooting

### WireGuard Interface Creation Fails

- Check kernel module: `lsmod | grep wireguard`
- Check capabilities: `getcap $(which beam.smp)` (should include `cap_net_admin+eip`)
- Check snap interfaces: `snap connections diode-node | grep -E 'network-control|firewall-control'`

### NIF Compilation Fails

- Ensure Rust is installed: `rustc --version`
- Check wireguardex dependency: `mix deps.compile wireguardex`

### Tests Skip Unexpectedly

- Check `WIREGUARD_ENABLED` environment variable
- Verify interface name doesn't conflict with existing interfaces
- Check listen port is available
