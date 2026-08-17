defmodule RemoteChain.ChainList do
  alias DiodeClient.Base16
  require Logger

  # Provider verdicts are re-evaluated after this TTL so providers that stop
  # following the chain (or recover from an outage) are reconsidered without a
  # node restart. Expired verdicts keep being served while the re-test runs in
  # the background, so callers never block on provider probes.
  @test_cache_ttl_ms :timer.minutes(5)

  # Stale-while-revalidate cache for the *list* of healthy providers per chain.
  # Distinct from @test_cache_ttl_ms (per-URL verdict) — this caches the filtered
  # set so `RemoteChain.ws_endpoints/1` never blocks the caller, even on the
  # very first call after startup. Cold callers fall back to the unfiltered
  # chainlist (deduped + known-broken providers stripped) and the probe runs in
  # a detached Task, not in the caller's process.
  @endpoint_cache_ttl_ms :timer.seconds(60)

  # How far ahead of the local clock a block timestamp may be (producer skew).
  @max_future_skew_seconds 60

  def rpc_endpoints(chain, additional_endpoints \\ []) do
    endpoints(chain, additional_endpoints)[:rpc]
    |> check_endpoints(chain)
  end

  @doc """
  WebSocket endpoints for `chain`, optionally extended with caller-supplied
  URLs.

  Only URLs from the community chainlist pass the staleness probe. Caller
  `additional_endpoints` (e.g. ChainImpl extras) are appended without
  filtering so env/ChainImpl overrides remain available via the canonical
  path RemoteChain -> ChainImpl -> ChainList.
  """
  def ws_endpoints(chain, additional_endpoints \\ []) do
    endpoints(chain, additional_endpoints)[:ws]
    |> check_endpoints(chain)
  end

  defp check_endpoints(endpoints, chain) do
    if endpoints == nil or endpoints == [] do
      Logger.error("No endpoints found for chain #{chain}")
    end

    endpoints
  end

  def endpoints(chain, additional_endpoints \\ []) do
    chain_id = RemoteChain.chainimpl(chain).chain_id()
    rpc = get(chain_id)["rpc"] || []

    chainlist_urls = Enum.map(rpc, fn entry -> entry["url"] end)
    filtered = filter_endpoints(chainlist_urls, chain)

    (filtered ++ additional_endpoints)
    |> Enum.uniq()
    |> Enum.group_by(fn endpoint ->
      cond do
        String.ends_with?(endpoint, "/http") -> :rpc
        String.ends_with?(endpoint, "/ws") -> :ws
        String.starts_with?(endpoint, "ws") -> :ws
        true -> :rpc
      end
    end)
  end

  def filter_endpoints(endpoints, chain) do
    cache_key = endpoint_cache_key(chain)
    schedule_endpoint_refresh(endpoints, chain)
    Globals.get(cache_key) || best_effort_urls(endpoints)
  end

  defp endpoint_cache_key(chain),
    do: {__MODULE__, :ws_endpoints, RemoteChain.chainimpl(chain).chain_id()}

  defp best_effort_urls(endpoints),
    do: endpoints |> Enum.uniq() |> Enum.reject(&rejected_provider?/1)

  defp schedule_endpoint_refresh(endpoints, chain) do
    chain_id = elem(endpoint_cache_key(chain), 2)

    Debouncer.immediate(
      {__MODULE__, :ws_endpoint_refresh, chain_id},
      fn ->
        refresh_endpoint_cache(endpoints, chain)
      end,
      @endpoint_cache_ttl_ms
    )
  end

  defp refresh_endpoint_cache(endpoints, chain) do
    filtered =
      endpoints
      |> best_effort_urls()
      |> probe_pass(chain)

    Globals.put(endpoint_cache_key(chain), filtered)
    :ok
  end

  defp probe_pass(urls, chain) do
    urls
    |> Task.async_stream(
      fn url -> {url, test?(url, chain)} end,
      timeout: :infinity,
      max_concurrency: 10
    )
    |> Enum.to_list()
    |> Enum.flat_map(fn
      {:ok, {url, true}} -> [url]
      _ -> []
    end)
  end

  def test?(url, chain) do
    key = {__MODULE__, :test, url}

    case Globals.get(key) do
      nil ->
        refresh_test(url, chain)

      {_value, tested_at} = entry ->
        if expired?(tested_at) do
          schedule_test_refresh(url, chain)
        end

        elem(entry, 0)
    end
  end

  # Providers the chainlist sometimes lists but that we know are unusable.
  # Applied both before the probe (so we don't waste a slot probing them) and
  # after (so a URL that happens to pass the probe is still kept out of the
  # pool).
  defp rejected_provider?(url),
    do: String.contains?(url, "pocket.network") or String.contains?(url, "curie.radiumblock.co")

  defp expired?(tested_at) do
    System.monotonic_time(:millisecond) - tested_at > @test_cache_ttl_ms
  end

  defp refresh_test(url, chain) do
    key = {__MODULE__, :test, url}

    Globals.locked({__MODULE__, :test_lock, url}, fn ->
      case Globals.get(key) do
        nil ->
          run_test(url, chain)

        {value, _tested_at} ->
          value
      end
    end)
  end

  defp schedule_test_refresh(url, chain) do
    key = {__MODULE__, :test, url}

    # Debounced so concurrent callers on the hot RPC path trigger at most one
    # background re-probe per TTL, and never block on it. Skips the probe if
    # another process already refreshed the verdict in the meantime.
    Debouncer.immediate2({__MODULE__, :test_refresh, url}, fn ->
      case Globals.get(key) do
        {_value, tested_at} ->
          if expired?(tested_at), do: run_test(url, chain)

        nil ->
          run_test(url, chain)
      end
    end)
  end

  defp run_test(url, chain) do
    Logger.info("Testing #{url} for #{chain}")
    ret = do_test?(url, chain)
    Logger.info("Tested #{url} for #{chain} and got #{ret}")
    Globals.put({__MODULE__, :test, url}, {ret, System.monotonic_time(:millisecond)})
    ret
  end

  def do_test?("ws" <> _ = ws_endpoint, chain) do
    pid = RemoteChain.WSConn.start(self(), chain, ws_endpoint)

    ret =
      if :ok ==
           RemoteChain.WSConn.send_request(
             pid,
             %{
               "jsonrpc" => "2.0",
               "id" => 99,
               "method" => "eth_chainId",
               "params" => []
             }
             |> Poison.encode!(),
             10_000
           ) do
        receive do
          {:response, _ws_url, %{"id" => 99, "result" => _chain_id}} ->
            current_block?(pid, chain)

          {:DOWN, _ref, :process, ^pid, _reason} ->
            false
        after
          3_000 ->
            false
        end
      else
        false
      end

    RemoteChain.WSConn.close(pid)
    ret
  after
    false
  end

  def do_test?(url, chain) do
    with {:ok, _chain_id} <- RemoteChain.HTTP.rpc(url, "eth_chainId", []),
         {:ok, block} <- RemoteChain.HTTP.rpc(url, "eth_getBlockByNumber", ["latest", false]) do
      block_current?(chain, block)
    else
      _ -> false
    end
  end

  defp current_block?(pid, chain) do
    if :ok ==
         RemoteChain.WSConn.send_request(
           pid,
           %{
             "jsonrpc" => "2.0",
             "id" => 100,
             "method" => "eth_getBlockByNumber",
             "params" => ["latest", false]
           }
           |> Poison.encode!(),
           10_000
         ) do
      receive do
        {:response, _ws_url, %{"id" => 100, "result" => block}} when is_map(block) ->
          block_current?(chain, block)
      after
        3_000 ->
          false
      end
    else
      false
    end
  end

  @doc """
  Whether the provider's latest block is recent enough, i.e. the provider is
  still following the chain head. Some providers (observed with Oasis Sapphire)
  keep responding to requests while stuck on an old block, which makes them
  unusable as block sources even though they pass an `eth_chainId` check.

  The age cutoff is shared with `RemoteChain.WSConn.stale_at?/3` (the same
  `@stale_threshold_intervals` constant), so an endpoint that passes here
  will not be flagged as stale by the WSConn's `:ping` handler. Future clock
  skew is bounded separately by `@max_future_skew_seconds` because the
  staleness predicate only checks how stale a `lastblock_at` is — never how
  far in the future it sits.

  Frozen chains (see `RemoteChain.frozen?/1`) have a fixed head; any
  provider that returns a block matching `RemoteChain.final_block_number/1`
  is considered current regardless of timestamp age, because age and
  staleness are not meaningful when the chain will never produce a newer
  block.
  """
  def block_current?(chain, block) when is_map(block) do
    cond do
      RemoteChain.frozen?(chain) ->
        final = RemoteChain.final_block_number(chain)
        is_integer(final) and current_by_block_number?(block, final)

      is_binary(block["timestamp"]) ->
        block_current_by_timestamp(chain, block["timestamp"])

      true ->
        false
    end
  end

  def block_current?(_chain, _block), do: false

  defp block_current_by_timestamp(chain, timestamp) do
    block_ts = Base16.decode_int(timestamp)
    now = System.os_time(:second)
    age = now - block_ts

    age >= -@max_future_skew_seconds and
      not RemoteChain.WSConn.stale_at?(block_age_to_lastblock_at(now, age), chain)
  end

  defp current_by_block_number?(%{"number" => number}, final) when is_binary(number) do
    Base16.decode_int(number) == final
  end

  defp current_by_block_number?(_block, _final), do: false

  @doc false
  def timestamp_current?(max_age_seconds, block_timestamp)
      when is_integer(max_age_seconds) and is_integer(block_timestamp) do
    age = System.os_time(:second) - block_timestamp
    age >= -@max_future_skew_seconds and age <= max_age_seconds
  end

  @doc false
  def max_block_age_seconds(chain) do
    RemoteChain.chainimpl(chain).expected_block_intervall() *
      RemoteChain.WSConn.stale_threshold_intervals()
  end

  # Reconstruct a synthetic `lastblock_at` so we can reuse `WSConn.stale_at?/3`
  # for the staleness check. The predicate only looks at `DateTime.diff/3`,
  # so any reference point with the right age is equivalent.
  defp block_age_to_lastblock_at(now, age) do
    DateTime.from_unix!(now - age)
  end

  @loaded_key {__MODULE__, :loaded}

  def get(chain_id) do
    key = cache_key(chain_id)

    case Globals.get(key) do
      nil ->
        Globals.locked({__MODULE__, :load_chains}, fn ->
          ensure_loaded()
          Globals.get(key)
        end)

      chain ->
        chain
    end
  end

  defp cache_key(chain_id), do: {__MODULE__, chain_id}

  defp ensure_loaded() do
    if Globals.get(@loaded_key) != true do
      refresh_chains()
      Globals.put(@loaded_key, true)
    end
  end

  defp refresh_chains() do
    file_path()
    |> File.read!()
    |> load_chains_from_json!()
    |> put_chains()
  end

  @doc false
  def refresh_chains(chains) when is_list(chains), do: put_chains(chains, only_cached: true)

  defp load_chains_from_json!(json) when is_binary(json) do
    json
    |> Jason.decode!()
    |> chains_to_map()
  end

  defp chains_to_map(chains) do
    Map.new(chains, fn %{"chainId" => id} = chain -> {id, chain} end)
  end

  defp put_chains(chains, opts \\ [])

  defp put_chains(chains, opts) when is_list(chains) do
    chains
    |> chains_to_map()
    |> put_chains(opts)
  end

  defp put_chains(chains_by_id, opts) when is_map(chains_by_id) do
    only_cached? = Keyword.get(opts, :only_cached, false)

    Enum.each(chains_by_id, fn {id, chain} ->
      key = cache_key(id)

      if not only_cached? or not is_nil(Globals.get(key)) do
        Globals.put(key, chain)
      end
    end)
  end

  def update() do
    case File.stat(Diode.data_dir("chains.json"), time: :posix) do
      {:error, _} ->
        download_update()

      {:ok, %{mtime: mtime}} ->
        if mtime < System.os_time(:second) - :timer.hours(24) * 7 do
          download_update()
        end
    end
  end

  defp download_update() do
    json =
      HTTPoison.get!("https://chainlist.org/rpcs.json")
      |> Map.get(:body)

    # Just ensure it's valid JSON
    {:ok, _chains} = Jason.decode(json)
    File.write!(Diode.data_dir("chains.json"), json)
    Globals.pop(@loaded_key)
    refresh_chains()
    :updated
  end

  def file_path() do
    updated_file = Diode.data_dir("chains.json")

    if File.exists?(updated_file) do
      updated_file
    else
      Path.join([:code.priv_dir(:diode), "rpcs.json"])
    end
  end
end
