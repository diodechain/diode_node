# Plan: keep NodeProxy out of the endpoint-probe slow path

## Problem statement

`RemoteChain.NodeProxy` for `Chains.Base` (and potentially any chain whose
chainlist has slow / unresponsive providers) can become unresponsive for tens
of seconds at a time. The GenServer is sitting inside
`RemoteChain.ChainList.filter_endpoints/2 → Task.async_stream → Enum.to_list`,
with `Task.Supervised` running up to 10 concurrent HTTP / WS health probes
against all chainlist URLs. The current state on `us1` confirms the
consequence: 137 k messages queued, `connections: %{}`, `lastblocks`
40 hours stale, and no Base log entries since `2026-08-12T21:40Z`.

Two callers inside `lib/remote_chain/node_proxy.ex` end up calling
`RemoteChain.ws_endpoints/1` synchronously in the GenServer process:

| Call site | Trigger | Hot? |
| --- | --- | --- |
| `init/1` → `ensure_connections/1` (node_proxy.ex:49) | VM startup | once |
| `handle_cast(:ensure_connections, …)` (node_proxy.ex:149–150) | any connection drop / prune | yes, debounced 5 s |
| `handle_call({:rpc, method, params}, …)` (node_proxy.ex:99) | every JSON-RPC request | **yes, very hot** |

The third row is the worst: every inbound RPC fires `ensure_connections/1`,
which calls `RemoteChain.ws_endpoints(chain)`,
which calls `filter_endpoints`,
which spawns a `Task.async_stream` over ~30 chainlist URLs and blocks the
GenServer until `Enum.to_list` returns. The per-call overhead is small when
all URLs are cached (`test?/2` returns instantly), but it becomes fatal the
moment one provider is slow — `Task.async_stream` waits for the slowest
batch and the GenServer can't process any message while it waits.

While the GenServer is blocked, `:new_block` messages from live WSConns
accumulate in the queue. `NodeProxy.lastblocks[url]` (the cache consulted
by `prune_stale_connections`) goes stale past the 40 s eviction window for
Base (`@stale_eviction_intervals 20 × expected_block_intervall 2 s`), every
live WSConn is evicted as "data-stale", and the eviction triggers another
`ensure_connections` cast. The cycle repeats until the GenServer is
permanently stuck.

This plan addresses **only** the synchronous-call-in-the-GenServer part
(Bug A). Bug B — `data_stale?/4` preferring `lastblocks[url]` over
`WSConn.lastblock_at/1` — is left as-is: once Bug A is fixed, the cache
will track real block arrivals and Bug B stops being reachable in
practice. Bug B can be revisited later if needed.

## Goal

`RemoteChain.ws_endpoints/1` (and its RPC sibling) must **never block
the calling process**. The NodeProxy GenServer should always be able to
process incoming messages — including `:new_block`, RPC requests, and
`:ensure_connections` casts — within a few microseconds of calling
`ws_endpoints/1`.

Provider health probes still need to run, and verdicts still need to
be reasonably fresh: a provider that goes from healthy → unhealthy
should drop out of the endpoint list within a bounded time, and a
provider that recovers should come back within a bounded time.

## Approach (high-level)

Add a **stale-while-revalidate cache** in front of `filter_endpoints/2`.
The cache stores the last filtered URL list per chain (keyed by
`chain_id`). The cache is read on every call (microseconds, ETS lookup)
and never blocks the caller. A background refresh runs in a `Task`
process spawned via `Debouncer.immediate2/3` (the same debounce pattern
already used by `schedule_test_refresh/2`).

When the cache is cold (first call after startup or after a chainlist
refresh), `filter_endpoints/2` returns the **unfiltered** chainlist
URLs immediately and schedules the probe in the background. The first
slow call still happens — but it happens off the GenServer, in a
detached worker. After at most one probe cycle, the cache is populated
and every subsequent call returns instantly.

### Why stale-while-revalidate and not "block on first call"

The NodeProxy runs `ensure_connections/1` from `init/1`. If the very
first `ws_endpoints/1` call blocks until the probe finishes, the
`RemoteChain.Sup` startup of Base (and every chain) will hang on every
node restart until the chainlist probe succeeds. Today this is masked
because `Globals` already caches per-URL verdicts (`@test_cache_ttl_ms`
= 5 min), so most chains boot quickly. But for the cold-cache path we
still want zero blocking.

### Why a per-chain cache and not a global one

The cache value depends on the chain (its `chain_id`) and on the
chainlist snapshot that was current when the cache was populated. When
`RemoteChain.ChainList.download_update/0` refreshes `chains.json` from
`chainlist.org`, the endpoint list cache must be invalidated so the
next probe picks up new URLs. Keying by `chain_id` makes invalidation
straightforward (`Globals.pop({__MODULE__, :ws_endpoints, chain_id})`
for every cached chain).

### Why cache `filter_endpoints` output and not the raw chainlist

`filter_endpoints` already does two things we want:
1. `Enum.uniq/1` — duplicate chainlist entries.
2. The `Enum.reject` for `pocket.network` and `curie.radiumblock.co`.
3. The health probe via `test?/2`.

The cache wraps (1)–(3) so callers always see the filtered, deduped,
probe-validated list. New chainlist URLs (added by chainlist.org) become
visible as soon as the next refresh runs, just like today.

## Detailed design

### Module: extend `RemoteChain.ChainList`

No new module is needed — the cache is small and only `ChainList` owns
the probe logic. Add a `@endpoint_cache_ttl_ms` constant and a
`@endpoint_cache_key/1` helper.

```elixir
# How long a cached endpoint list is considered fresh. Short enough that a
# provider going bad is reflected within one TTL, long enough that we don't
# re-probe on every RPC request. Independent of @test_cache_ttl_ms (per-URL
# verdict) — this caches the *list*, not individual verdicts.
@endpoint_cache_ttl_ms :timer.seconds(60)

defp endpoint_cache_key(chain), do: {__MODULE__, :ws_endpoints, chain_id(chain)}

defp chain_id(chain), do: RemoteChain.chainimpl(chain).chain_id()
```

Cache value shape:

```elixir
{urls :: [String.t()], refreshed_at_ms :: integer()}
```

#### `filter_endpoints/2` becomes the cache-aware entry point

```elixir
def filter_endpoints(endpoints, chain) do
  cache_key = endpoint_cache_key(chain)

  case Globals.get(cache_key) do
    {urls, ts} when is_list(urls) ->
      if cache_stale?(ts) do
        schedule_endpoint_refresh(endpoints, chain, cache_key)
      end
      urls

    nil ->
      # Cold cache: kick off a background probe and return the raw URLs
      # best-effort. The WSConn layer will fail any unhealthy URL naturally
      # on connect; the next probe cycle will filter it out.
      schedule_endpoint_refresh(endpoints, chain, cache_key)
      Enum.uniq(endpoints)
  end
end

defp cache_stale?(ts),
  do: System.monotonic_time(:millisecond) - ts > @endpoint_cache_ttl_ms
```

The current body of `filter_endpoints` moves into a private
`do_filter_endpoints/2` that the background refresh calls.

#### Background refresh (Debouncer-based)

```elixir
defp schedule_endpoint_refresh(endpoints, chain, cache_key) do
  chain_id = elem(cache_key, 2)

  Debouncer.immediate2({__MODULE__, :ws_endpoint_refresh, chain_id}, fn ->
    case Globals.get(cache_key) do
      {_urls, ts} ->
        if cache_stale?(ts), do: do_refresh_endpoint_cache(endpoints, chain, cache_key)

      nil ->
        do_refresh_endpoint_cache(endpoints, chain, cache_key)
    end
  end)
end

defp do_refresh_endpoint_cache(endpoints, chain, cache_key) do
  filtered = do_filter_endpoints(endpoints, chain)
  Globals.put(cache_key, {filtered, System.monotonic_time(:millisecond)})
end
```

`Debouncer.immediate2/3` already enforces "at most one in-flight job per
key", so concurrent callers during cold cache trigger exactly one
probe. The probe runs in a worker process spawned by `Debouncer`, never
in the calling (GenServer) process.

#### Invalidate on chainlist refresh

`RemoteChain.ChainList.download_update/0` and `refresh_chains/0` need to
clear the endpoint cache so the next call picks up the new URLs. Add:

```elixir
defp put_chains(chains_by_id, opts) when is_map(chains_by_id) do
  only_cached? = Keyword.get(opts, :only_cached, false)

  Enum.each(chains_by_id, fn {id, chain} ->
    key = cache_key(id)

    if not only_cached? or not is_nil(Globals.get(key)) do
      Globals.put(key, chain)
      Globals.pop(endpoint_cache_key_for_id(id))
    end
  end)
end
```

(Implementation detail: expose `endpoint_cache_key/1` as
`endpoint_cache_key_for_id/1` for the invalidation helper, or inline the
key construction.)

#### `rpc_endpoints/2` parallel

Mirror the same change in `rpc_endpoints/2` — it shares the
`endpoints/2` helper, so the fix at the `endpoints/2` boundary covers
both `ws_endpoints/2` and `rpc_endpoints/2`. The `edge.ex` caller
(`forward_raw_transaction/2`) is on the slow path (broadcasts raw
transactions) but the same fix removes its blocking risk.

### What stays unchanged

- The env-var override (`CHAINS_BASE_WS=...` and friends) keeps working
  unchanged — `RemoteChain.maybe_override/3` is consulted *before*
  `ChainImpl.ws_endpoints/0` is called, so a configured value bypasses
  both the probe and the cache.
- `ChainList.test?/2`, `test_cache_ttl_ms`, and the per-URL verdict
  cache — all unchanged. They continue to feed `filter_endpoints`.
- `NodeProxy.ensure_connections/1`, `prune_stale_connections/1`, and the
  rest of the GenServer — unchanged. Once `RemoteChain.ws_endpoints/1`
  stops blocking, the GenServer is no longer the bottleneck.
- The `RemoteChain.Sup` topology — unchanged. No new supervisor child.
- Bug B (`data_stale?/4` cache preference) — explicitly out of scope.

## Test plan

Mirror `lib/remote_chain/chain_list.ex` with
`test/remote_chain/chain_list_test.exs`. Add a new
`describe "filter_endpoints/2 cache"` block (matching the existing
`describe "test?/2 caching"` style).

### Required regression tests

1. **Cold cache returns immediately and schedules background refresh.**
   Use a URL whose mock provider blocks for several seconds
   (`Process.sleep(:infinity)` or a 10 s `:timer.sleep`). Call
   `RemoteChain.ChainList.filter_endpoints([slow_url], Chains.Anvil)`
   with no pre-seeded cache and assert it returns within `< 100 ms`
   and the slow URL appears in the returned list. Wait for the
   background refresh to settle (poll the cache key with a timeout) and
   assert the slow URL is now excluded.

2. **Warm cache returns from Globals without touching the network.**
   Pre-seed the cache via `Globals.put(cache_key, {urls, ts})` and stub
   `HTTPoison` (or use the existing `with_http_mock/2` and call
   `Plug.Cowboy.shutdown/1` before the assertion) to ensure no probe
   runs. Call `filter_endpoints/2` and assert it returns the seeded
   URLs immediately.

3. **Stale cache schedules a background refresh but still returns the
   stale value.** Pre-seed the cache with
   `{ts: System.monotonic_time(:millisecond) - :timer.seconds(120)}`,
   mock a fresh HTTP provider, call `filter_endpoints/2`, and assert
   the immediate return is the stale list while the cache value updates
   to the fresh verdict within `~ 5 s`.

4. **Concurrent cold-cache callers trigger exactly one probe.** Seed a
   `mock_ref` counter that increments on every HTTP request. Spawn 20
   concurrent `filter_endpoints/2` calls against a fresh cache and
   assert the counter equals 1 (per chain, per probe).

5. **chainlist.json refresh invalidates the cache.** Pre-seed the
   endpoint cache for a known chain_id, call
   `RemoteChain.ChainList.refresh_chains/1` with an updated chain entry
   that swaps in a new URL, and assert
   `Globals.get(endpoint_cache_key(chain))` is `nil`.

6. **Public `RemoteChain.ws_endpoints/1` honours env overrides even
   with the cache populated.** Mirror the existing
   `RemoteChainTest "ws_endpoints/1 env override"` tests so we confirm
   the cache layer sits below `maybe_override/3`.

7. **Pre-seeded failure cache short-circuits (regression for
   `pre-seeds failed verdicts`).** The existing
   `RemoteChain.ChainListTest "drops chainlist URLs that fail the
   health probe"` already covers the warm-cache path; extend it to
   assert that a stale entry still serves the cached `false` until the
   background refresh re-evaluates.

### Required end-to-end / integration test

Add a `RemoteChain.NodeProxyTest` case proving the GenServer stays
responsive while a slow provider is in the list. Sketch:

- Seed the `EndpointListCache` for `Chains.Anvil` with one URL that
  points at a `Task` that blocks on `receive`.
- Call `RemoteChain.NodeProxy.rpc(Chains.Anvil, "eth_blockNumber", [])`
  via `GenServer.call` with a short timeout (e.g., 500 ms) and assert
  the call returns (with whatever the existing connection pool
  returns) **without timing out**, demonstrating the GenServer was not
  blocked by `filter_endpoints`.

This test does not require the new module to be merged in any specific
way; it can be written against the public `RemoteChain.ws_endpoints/1`
contract.

### Required manual verification

- Run `mix test` and `mix lint` (the project does both on CI; `mix lint`
  is currently the CI gate per `docs/testing.md`).
- Boot a fresh node (the `dev` script) and confirm:
  - `tail -f logs/Elixir.Chains.Base.log` shows incoming RPCs within
    seconds of `mix run`.
  - `tail -f error.log` does not show the `Evicting data-stale WSConn`
    storm at startup.

## Roll-out

1. Land the `filter_endpoints/2` cache + background refresh + chainlist
   invalidation as one PR, with the regression tests above. No
   behaviour change for warm-cache callers.
2. Land a follow-up PR for Bug B (out of scope here).
3. On `us1`, the current deadlock can be broken by killing the Base
   `RemoteChain.NodeProxy` via:
   ```bash
   ssh us1 '/opt/diode_node/bin/diode_node rpc \
     ":global.whereis_name({RemoteChain.NodeProxy, Chains.Base}) \
      |> Process.exit(:kill) |> IO.inspect()"'
   ```
   The supervisor will respawn it; with this PR merged, the respawned
   process will populate the cache and stay responsive.

## Out of scope

- Bug B (`data_stale?/4` cache preference in `prune_stale_connections`).
- Faster per-URL probes (today's HTTP timeouts come from
  `HTTPoison`'s default 8 s connect / 5 s recv).
- `RemoteChain.ChainList.update/0`'s hourly chainlist download — this
  PR only touches the invalidation of the endpoint cache when the
  download completes; the download cadence is unchanged.
- Any change to `RemoteChain.Sup`, `RemoteChain.RPCCache`,
  `RemoteChain.TxRelay`, or `RemoteChain.NonceProvider`.

## Open questions

- Should the cache TTL be configurable via env var? `mix.exs` /
  `config/runtime.exs` would expose `@endpoint_cache_ttl_ms` so
  operators can shorten it (e.g., during a provider outage) or
  lengthen it (e.g., for chains with very stable providers). Default
  60 s is a reasonable starting point.
- Should we expose the cache contents for inspection (e.g.,
  `RemoteChain.ChainList.debug_endpoint_cache/1` returning
  `{urls, age_ms, refreshing?}`)? Useful for ops debugging and for
  the regression tests. Cheap to add; defer if scope grows.
- Should the cold-cache fallback list also drop `pocket.network` /
  `curie.radiumblock.co`? Today `filter_endpoints` does; with the
  cold-cache path returning `Enum.uniq(endpoints)`, those URLs would
  be present until the first refresh. Reject them in the cold-cache
  path too, to match the warm-cache behaviour exactly.