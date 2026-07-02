# Testing

This project uses [ExUnit](https://hexdocs.pm/ex_unit/ExUnit.html). **Regression tests are mandatory** for bug fixes and new behavior — see [AGENTS.md](../AGENTS.md#regression-tests-required).

## Quick commands

```bash
# Lint (CI runs this)
mix lint

# Single file (preferred while developing)
mix test test/network/rpc_http_test.exs

# Isolated tests without anvil / full app boot
DIODE_MINIMAL_TEST=1 mix test --no-start test/network/rpc_http_test.exs

# TURN unit tests only
mix test.turn

# Full suite (starts local anvil chain — slower)
mix test
```

CI currently runs `mix lint`. Tests are still required in every PR so regressions are caught locally and can be enabled in CI later.

## Layout

| Path | Purpose |
| --- | --- |
| `test/test_helper.exs` | ExUnit config, `TestHelper`, anvil chain startup |
| `test/helpers/` | Shared test modules compiled via `elixirc_paths(:test)` |
| `test/network/` | RPC, WebSocket, Edge, and HTTP tests |
| `test/diode/turn/` | TURN server unit tests (`mix test.turn`) |

Mirror `lib/` module paths when adding new tests.

## Regression test patterns

### HTTP / Plug routes

Call the plug with `Plug.Test` — no need to bind a port:

```elixir
defmodule Network.RpcHttpTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  import Plug.Test

  @opts Network.RpcHttp.init([])

  test "GET /api renders without error" do
    conn = :get |> conn("/api") |> Network.RpcHttp.call(@opts)
    assert conn.status == 200
    assert String.contains?(conn.resp_body, "dio_version")
  end
end
```

Full example: `test/network/rpc_http_test.exs` (covers server notification docs that omit `example_request`).

### Bug-fix checklist

1. Reproduce the failure on `main` (crash, wrong response, missing field).
2. Add a test that asserts the broken symptom.
3. Confirm the test fails before your fix and passes after.
4. Keep the test focused — one scenario per test when possible.

### Optional keys and rendering

When maps omit keys (e.g. notification docs without `example_request`), use Access syntax in templates (`doc[:field]`) and test both the data shape and the rendered output.

### Tags and environment

- `@tag :requires_wireguard` — excluded unless `WIREGUARD_ENABLED=1`
- `DIODE_MINIMAL_TEST=1` — skips anvil startup in `test_helper.exs` for fast isolated tests

## Integration tests

Multi-node and chain-dependent tests use `TestHelper` (`reset/0`, `start_clones/1`, wallets, anvil). See existing files under `test/network/` for WebSocket ticket billing and Edge e2e patterns.

For WireGuard-specific manual and automated steps, see [TEST_EXECUTION_GUIDE.md](../TEST_EXECUTION_GUIDE.md).
