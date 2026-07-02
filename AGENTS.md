# Agent and contributor guidelines

Instructions for humans and coding agents working in this repository.

## Regression tests (required)

Every change that fixes a bug or adds behavior **must** include regression tests in the same PR.

### When tests are required

| Change | Requirement |
| --- | --- |
| Bug fix | At least one test that fails on the base branch and passes with the fix |
| New RPC method, HTTP route, or WebSocket behavior | Tests for success and relevant error paths |
| Template / docs rendering (e.g. `GET /api`) | Test that rendering completes and asserts key output |
| Refactor with behavior change | Update or add tests covering the changed behavior |

If a test truly cannot be added (e.g. needs hardware only available in production), say why in the PR description and document the manual verification steps.

### How to write regression tests

- Place tests under `test/`, mirroring `lib/` layout (e.g. `lib/network/rpc_http.ex` → `test/network/rpc_http_test.exs`).
- Prefer `async: true` when the test does not mutate shared global state.
- **HTTP routes:** use `Plug.Test` and call the plug directly. See `test/network/rpc_http_test.exs`.
- **Isolated unit tests:** use `DIODE_MINIMAL_TEST=1 mix test --no-start path/to/test.exs` when the full anvil chain is not needed (see `test/test_helper.exs`).
- **Integration / multi-node:** use `TestHelper` and existing patterns in `test/network/`.
- Name tests after the failure they prevent (e.g. "GET /api renders all API docs including server notifications").
- Assert the symptom that was broken (status code, crash, missing field, wrong encoding), not only happy-path internals.

### Before opening or updating a PR

```bash
mix lint
mix test test/path/to/your_test.exs
```

Run the narrowest test file that covers your change. Run `mix test` when touching shared infrastructure.

## Elixir style

- Match surrounding module conventions (naming, helpers, error tuples).
- Prefer `with` for multi-step success pipelines; use `cond` for multiple unrelated branches.
- Avoid `try/rescue` unless translating expected exceptions at a boundary.
- Keep changes minimal; reuse existing helpers instead of duplicating logic.
- `mix format` and `mix lint` must pass (`elixirc_options: [warnings_as_errors: true]`).

## Architecture notes

- JSON-RPC handlers live under `lib/network/` (`Network.Rpc`, `Network.RpcHttp`, `Network.RpcWs`).
- Static API documentation is built from `Network.RpcDocs` and rendered by `Network.RpcHttp` at `GET /api`.
- Chain and ticket logic use `RemoteChain`, `TicketStore`, and `TestHelper` in tests.

## Further reading

- [docs/testing.md](docs/testing.md) — test layout, commands, and examples
- [TEST_EXECUTION_GUIDE.md](TEST_EXECUTION_GUIDE.md) — WireGuard and integration test setup
