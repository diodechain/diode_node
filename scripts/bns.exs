# Usage:
#   elixir bns.exs                         # process all names from bns_2026_08_01.json
#   elixir bns.exs knusperhaus             # only the given name(s)
#   elixir bns.exs --dry-run knusperhaus   # classify + print plan, no transactions
#   elixir bns.exs knusperhaus.diode foo.base
#
Mix.install(
  [
    {:diode, path: __DIR__ <> "/../"},
    {:dets_plus, "~> 2.1"}
  ],
  config: [diode: [no_start: true]]
)

alias DiodeClient.{Secp256k1, Base16, Hash, Wallet}
alias Script.BnsMigrate

defmodule BnsLog do
  @doc "Print `msg` prefixed with UTC `HH:MM:SS` (each non-empty line)."
  def puts(msg) when is_binary(msg) do
    ts = timestamp()

    msg
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> "#{ts} #{line}"
    end)
    |> IO.puts()
  end

  def puts(msg), do: puts(to_string(msg))

  def inspect(term, opts \\ []) do
    puts(Kernel.inspect(term, opts))
    term
  end

  defp timestamp do
    Calendar.strftime(Time.utc_now(), "%H:%M:%S")
  end
end

{dry_run, only_names} =
  case BnsMigrate.parse_argv(System.argv()) do
    {:ok, %{dry_run: dry_run, names: names}} ->
      only =
        names
        |> Enum.map(&BnsMigrate.normalize_name/1)
        |> Enum.reject(&(&1 == ""))

      {dry_run, only}

    {:error, {:unknown_args, unknown}} ->
      BnsLog.puts("""
      Unknown argument(s): #{Enum.join(unknown, ", ")}

      Usage:
        elixir bns.exs [--dry-run] [name ...]
      """)

      System.halt(1)
  end

# Base reads for classify/dry-run are all `latest` — prefer public WS with optional
# archive prepend. Exclusive `!` archive was 429-storming SimplyStaking.
base_ws =
  "wss://spectrum-01.simplystaking.xyz/oa1qWbIerDZu7T/BoDQDCB1Yh1pqA/base/mn/8453/shared/archive/ws/"

System.put_env(
  "CHAINS_BASE_WS_FALLBACK",
  "wss://base-rpc.publicnode.com wss://base.gateway.tenderly.co"
)

if dry_run do
  # Dry-run: skip archive + ChainList probe storm; pin known-good public endpoints.
  System.put_env(
    "CHAINS_BASE_WS",
    "wss://base-rpc.publicnode.com wss://base.gateway.tenderly.co"
  )

  System.put_env(
    "CHAINS_BASE_RPC",
    "https://mainnet.base.org https://base.meowrpc.com"
  )

  BnsLog.puts("Base WS: publicnode + tenderly (dry-run)")
else
  System.put_env("CHAINS_BASE_WS", "+" <> base_ws)
  BnsLog.puts("Base WS preferred: #{base_ws} (+ ChainList / fallback public WS)")
end

{:ok, _pid} =
  Supervisor.start_link([{RemoteChain.Sup, Chains.Base}], strategy: :rest_for_one)

{:ok, _pid} = Supervisor.start_link([{RemoteChain.Sup, Chains.Diode}], strategy: :rest_for_one)
:persistent_term.put(:identity, Secp256k1.generate())
Logger.configure(level: :warning)

defmodule Helper do
  require Logger
  alias DiodeClient.{ABI, Base16, Hash, Wallet}
  alias Script.BnsMigrate

  # Base Collab contracts (DiodeClient.Contracts.Factory.contracts(Shell.Base))
  @factory Base16.decode("0x1A36092D88FB73692EE7C502978D634C4AFCC486")
  # BNS proxy — implementation is BNSAdmin.sol v400 (admin can re-Register owned names)
  @bns Base16.decode("0x87C1D1304944A9EA16AF18CB777E3CEE0D3DACEA")
  @drive_member Base16.decode("0x3D565EC28595C1A0710ABCBD8C0F979D31E38704")
  @diode_bns Base16.decode("0xAF60FAA5CD840B724742F1AF116168276112D6A6")
  @null BnsMigrate.zero_address()
  # BNSAdmin.isAdmin/1 — must match diode_glmr.key
  @bns_admin Base16.decode("0x7102533B13b950c964efd346Ee15041E3e55413f")

  def factory, do: @factory
  def bns, do: @bns
  def drive_member, do: @drive_member
  def null, do: @null
  def bns_admin, do: @bns_admin

  def submit_tx(tx, retries \\ 30) do
    if retries == 0 do
      raise "Failed to submit transaction after retries exhausted"
    end

    try do
      Shell.submit_tx(tx)
      |> case do
        tx_id when is_binary(tx_id) ->
          BnsLog.inspect(DiodeClient.Transaction.hash(tx) |> Base16.encode())
          BnsLog.inspect(tx_id)
          BnsMigrate.await_tx_ref(tx_id, tx)

        :already_known ->
          tx_id = DiodeClient.Transaction.hash(tx) |> Base16.encode()
          BnsMigrate.await_tx_ref(tx_id, tx)

        {:error, error} ->
          cond do
            out_of_gas_error?(error) ->
              raise "Out of gas / insufficient funds, stopping: #{inspect(error)}"

            BnsMigrate.nonce_too_low_error?(error) ->
              # Same signed payload can never recover — caller must rebuild with a new nonce.
              {:error, {:nonce_too_low, error}}

            true ->
              Logger.error(
                "Failed to submit transaction: #{inspect(error)}, retrying... in 10 seconds"
              )

              Process.sleep(10_000)
              submit_tx(tx, retries - 1)
          end
      end
    catch
      :exit, reason ->
        Logger.error("TX submit exited #{inspect(reason)}, retrying... in 10 seconds")
        Process.sleep(10_000)
        submit_tx(tx, retries - 1)
    end
  end

  def await_txs(pending) do
    pending
    |> Enum.reverse()
    |> Enum.with_index(1)
    |> Enum.each(fn {{tx_id, _tx} = ref, idx} ->
      BnsLog.puts("Awaiting TX-#{idx} #{tx_id} ...")
      Shell.await_tx_id(ref)
    end)
  end

  def ensure_gas!(wallet) do
    balance =
      rpc_retry!(fn ->
        Shell.get_balance(Chains.Base, Wallet.address!(wallet))
      end)

    # Shell.ether/1 only accepts integers — use finney (0.001 ether).
    if not BnsMigrate.sufficient_gas?(balance) do
      raise "Out of gas / insufficient funds, stopping: balance=#{balance} wei (#{Base16.encode(Wallet.address!(wallet))})"
    end

    balance
  end

  defp out_of_gas_error?(error) do
    message =
      cond do
        is_binary(error) -> error
        is_map(error) -> "#{Map.get(error, "message", "")} #{inspect(error)}"
        true -> inspect(error)
      end
      |> String.downcase()

    String.contains?(message, "insufficient funds") or
      String.contains?(message, "out of gas") or
      String.contains?(message, "gas required exceeds") or
      String.contains?(message, "max fee per gas less than block base fee")
  end

  defp disconnect_error?(error) do
    message = Exception.message(error) |> String.downcase()

    String.contains?(message, "disconnect") or String.contains?(message, "rpc error") or
      String.contains?(message, "not_connected") or BnsMigrate.rate_limit_error?(error)
  end

  @doc """
  Retry a bang RPC thunk on disconnect / GenServer timeout, then re-raise.
  """
  def rpc_retry!(fun, retries \\ 8) when is_function(fun, 0) do
    try do
      fun.()
    rescue
      e in RuntimeError ->
        rate_limited? =
          BnsMigrate.rate_limit_error?(e) or rate_limit_window?() or
            disconnect_during_reconnect?(e)

        if (disconnect_error?(e) or rate_limited?) and retries > 0 do
          Logger.warning(
            "RPC #{if rate_limited?, do: "rate-limited/reconnect", else: "disconnect"}, retrying... (#{retries} left)"
          )

          Process.sleep(BnsMigrate.rpc_backoff_ms(retries, rate_limited?))
          rpc_retry!(fun, retries - 1)
        else
          reraise e, __STACKTRACE__
        end
    catch
      :exit, {:timeout, _} = reason ->
        if retries > 0 do
          Logger.warning("RPC timeout, retrying... (#{retries} left)")
          Process.sleep(BnsMigrate.rpc_backoff_ms(retries, rate_limit_window?()))
          rpc_retry!(fun, retries - 1)
        else
          exit(reason)
        end
    end
  end

  defp disconnect_during_reconnect?(error) do
    message = Exception.message(error) |> String.downcase()

    String.contains?(message, "disconnect") or String.contains?(message, "not_connected") or
      String.contains?(message, "no worker")
  end

  def mark_rate_limited! do
    :persistent_term.put(
      {__MODULE__, :rate_limited_until},
      System.monotonic_time(:millisecond) + 15_000
    )
  end

  def rate_limit_window? do
    now = System.monotonic_time(:millisecond)

    helper_until = :persistent_term.get({__MODULE__, :rate_limited_until}, 0)
    proxy_until = :persistent_term.get({RemoteChain.NodeProxy, :rate_limited_until}, 0)

    now < max(helper_until, proxy_until)
  end

  @doc """
  Block until eth_blockNumber succeeds on both chains so classification does not
  race the initial WS handshake / endpoint probe.
  """
  def await_chains_ready! do
    BnsLog.puts("Waiting for Base + Diode RPC ...")

    parallel_map!([
      fn ->
        rpc_retry!(fn -> RemoteChain.RPC.block_number(Chains.Base) end, 12)
      end,
      fn ->
        rpc_retry!(fn -> RemoteChain.RPC.block_number(Chains.Diode) end, 12)
      end
    ])

    BnsLog.puts("RPC ready.")
  end

  @doc """
  Run independent thunks in parallel. On any task exit, shut down siblings before
  re-raising so linked Task.async children cannot crash the caller later.
  """
  def parallel_map!(funs) when is_list(funs) do
    tasks = Enum.map(funs, &Task.async/1)

    try do
      Task.await_many(tasks, :infinity)
    catch
      :exit, reason ->
        Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
        exit(reason)
    end
  end

  def memo_table, do: :bns_rpc_memo

  def init_memo! do
    case :ets.whereis(memo_table()) do
      :undefined ->
        :ets.new(memo_table(), [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

      _tid ->
        :ok
    end
  end

  def memo_get(key) do
    case :ets.lookup(memo_table(), key) do
      [{^key, value}] -> {:ok, value}
      [] -> :miss
    end
  end

  def memo_put(key, value) do
    :ets.insert(memo_table(), {key, value})
    value
  end

  def memo_fetch(key, fun) when is_function(fun, 0) do
    case memo_get(key) do
      {:ok, value} -> value
      :miss -> memo_put(key, fun.())
    end
  end

  def memo_invalidate_account(chain, address) do
    :ets.delete(memo_table(), {:code, chain, address})
    memo_invalidate_account_state(chain, address)
  end

  def memo_invalidate_account_state(chain, address) do
    :ets.delete(memo_table(), {:owner, chain, address})
    :ets.delete(memo_table(), {:members, chain, address})
    :ok
  end

  def memo_put_deployed(salt, addr) when is_binary(salt) and is_binary(addr) do
    memo_put({:code, Chains.Base, addr}, true)
    memo_put({:identity_deployed, salt}, {addr, true})
  end

  def identity_salt(owner), do: BnsMigrate.identity_salt(owner)
  def repair_salt(owner), do: BnsMigrate.repair_salt(owner)

  def identity_address(salt) when is_binary(salt) and byte_size(salt) == 32 do
    # Pure CREATE2 — do not eth_call Create2Address (dominant 429 failure mode).
    BnsMigrate.base_create2_address(salt)
  end

  def identity_deployed?(salt) when is_binary(salt) and byte_size(salt) == 32 do
    memo_fetch({:identity_deployed, salt}, fn ->
      addr = identity_address(salt)
      {addr, has_code?(Chains.Base, addr)}
    end)
  end

  def identity_probes(owner) when is_binary(owner) do
    v1_salt = identity_salt(owner)
    r_salt = repair_salt(owner)
    v1_addr = identity_address(v1_salt)
    r_addr = identity_address(r_salt)

    codes =
      get_codes!(Chains.Base, [v1_addr, r_addr])
      |> Map.new()

    v1 = {v1_addr, Map.fetch!(codes, v1_addr)}
    repair = {r_addr, Map.fetch!(codes, r_addr)}
    memo_put({:identity_deployed, v1_salt}, v1)
    memo_put({:identity_deployed, r_salt}, repair)
    [v1, repair]
  end

  def has_code?(chain, address) do
    memo_fetch({:code, chain, address}, fn ->
      rpc_retry!(fn ->
        code = RemoteChain.RPC.get_code(chain, Base16.encode(address))
        Base16.decode(code) != ""
      end)
    end)
  end

  @doc """
  Batch `eth_getCode` for addresses not already memoized. Returns `[{addr, bool}]`.
  """
  def get_codes!(chain, addresses) when is_list(addresses) do
    uniq = Enum.uniq(addresses)

    {known, missing} =
      Enum.split_with(uniq, fn addr -> match?({:ok, _}, memo_get({:code, chain, addr})) end)

    known_pairs =
      Enum.map(known, fn addr ->
        {:ok, deployed?} = memo_get({:code, chain, addr})
        {addr, deployed?}
      end)

    missing_pairs =
      if missing == [] do
        []
      else
        fetch_codes_with_fallback!(chain, missing)
      end

    known_pairs ++ missing_pairs
  end

  defp fetch_codes_with_fallback!(chain, addresses) do
    try do
      codes =
        rpc_retry!(fn ->
          RemoteChain.RPC.get_code_many(chain, Enum.map(addresses, &Base16.encode/1))
        end)

      Enum.zip(addresses, codes)
      |> Enum.map(fn {addr, code} ->
        deployed? = Base16.decode(code) != ""
        memo_put({:code, chain, addr}, deployed?)
        {addr, deployed?}
      end)
    rescue
      e in RuntimeError ->
        Logger.warning(
          "get_code_many failed (#{Exception.message(e)}); falling back to sequential eth_getCode"
        )

        Enum.map(addresses, fn addr ->
          deployed? =
            rpc_retry!(fn ->
              code = RemoteChain.RPC.get_code(chain, Base16.encode(addr))
              Base16.decode(code) != ""
            end)

          memo_put({:code, chain, addr}, deployed?)
          {addr, deployed?}
        end)
    end
  end

  def null?(address), do: BnsMigrate.null_address?(address, @null)

  def resolve_owner(name) do
    case call_address_soft(Chains.Base, @bns, "ResolveOwner", ["string"], [name]) do
      {:ok, addr} ->
        addr

      {:error, error} ->
        BnsLog.puts("ResolveOwner(#{inspect(name)}) reverted: #{inspect(error)}")
        @null
    end
  end

  def resolve_destination(name) do
    case call_address_soft(Chains.Base, @bns, "Resolve", ["string"], [name]) do
      {:ok, addr} ->
        addr

      {:error, error} ->
        BnsLog.puts("Resolve(#{inspect(name)}) reverted: #{inspect(error)}")
        @null
    end
  end

  def diode_resolve_destination(name) do
    # Diode L1 BNS Resolve() eth_call is unreliable for historical names; read storage
    # the same way diode_client / the original dump does (slot 1 = names).
    name_hash = Hash.keccak_256(name)
    base = Hash.to_bytes32(1)
    dest_slot = Hash.keccak_256(name_hash <> base)

    rpc_retry!(fn ->
      RemoteChain.RPC.get_storage_at(
        Chains.Diode,
        Base16.encode(@diode_bns),
        Base16.encode(dest_slot, false)
      )
      |> Base16.decode()
      |> Hash.to_address()
    end)
  end

  def diode_resolve_owner(name) do
    name_hash = Hash.keccak_256(name)
    base = Hash.to_bytes32(1)

    owner_slot =
      Hash.keccak_256(name_hash <> base)
      |> :binary.decode_unsigned()
      |> Kernel.+(1)
      |> :binary.encode_unsigned()

    rpc_retry!(fn ->
      RemoteChain.RPC.get_storage_at(
        Chains.Diode,
        Base16.encode(@diode_bns),
        Base16.encode(owner_slot, false)
      )
      |> Base16.decode()
      |> Hash.to_address()
    end)
  end

  def owner_of(chain, identity) do
    memo_fetch({:owner, chain, identity}, fn ->
      call_address(chain, identity, "owner", [], [])
    end)
  end

  def members_of(chain, identity, retries \\ 5) do
    case memo_get({:members, chain, identity}) do
      {:ok, list} ->
        list

      :miss ->
        case call_address_array_soft(chain, identity, "Members") do
          {:ok, list} ->
            memo_put({:members, chain, identity}, list)

          {:error, reason}
          when reason in [:empty_result, :timeout, :disconnect] and retries > 0 ->
            # Fresh CREATE2 deploys can briefly return empty eth_call on lagging nodes.
            Process.sleep(2_000)
            members_of(chain, identity, retries - 1)

          {:error, error} ->
            raise "RPC error: #{inspect(error)} calling Members"
        end
    end
  end

  def non_owner_members(chain, identity) do
    owner = owner_of(chain, identity)
    Enum.reject(members_of(chain, identity), &(&1 == owner))
  end

  def broken_identity?(base_identity, l1_identity, base_has_code? \\ nil, l1_has_code? \\ nil) do
    base_code? =
      if is_boolean(base_has_code?),
        do: base_has_code?,
        else: has_code?(Chains.Base, base_identity)

    l1_code? =
      if is_boolean(l1_has_code?), do: l1_has_code?, else: has_code?(Chains.Diode, l1_identity)

    cond do
      not (base_code? and l1_code?) ->
        false

      true ->
        base_non_owners = non_owner_members(Chains.Base, base_identity)

        # Short-circuit: Base already has a fleet → not broken; skip L1 Members.
        if base_non_owners != [] do
          false
        else
          BnsMigrate.broken_identity?(
            true,
            true,
            [],
            non_owner_members(Chains.Diode, l1_identity)
          )
        end
    end
  end

  @doc """
  Fleet devices to seed onto the Base identity, taken from the Diode L1 origin
  identity (owner + Members). Falls back to the BNS name owner when the Diode
  identity is missing or when L1 `owner()` / `Members()` eth_call reverts.
  """
  def origin_fleet(name, bns_owner) do
    dest = diode_resolve_destination(name)

    cond do
      null?(dest) or not has_code?(Chains.Diode, dest) ->
        BnsMigrate.build_origin_fleet(bns_owner, nil, [], dest)

      true ->
        case call_address_soft(Chains.Diode, dest, "owner", [], []) do
          {:ok, id_owner} ->
            members = members_of_soft(Chains.Diode, dest)
            BnsMigrate.build_origin_fleet(bns_owner, id_owner, members, dest)

          {:error, error} ->
            BnsLog.puts(
              "L1 owner(#{Base16.encode(dest)}) for #{inspect(name)} reverted: #{inspect(error)}; using BNS owner only"
            )

            BnsMigrate.build_origin_fleet(bns_owner, nil, [], dest)
        end
    end
  end

  def members_complete?(identity, fleet, deployer) do
    BnsMigrate.members_complete?(members_of(Chains.Base, identity), fleet, deployer)
  end

  def call_address(chain, to, method, types, args) do
    case call_address_soft(chain, to, method, types, args) do
      {:ok, addr} -> addr
      {:error, error} -> raise "RPC error: #{inspect(error)} calling #{method}"
    end
  end

  def call_address_soft(chain, to, method, types, args) do
    data = ABI.encode_call(method, types, args) |> Base16.encode()

    try do
      case RemoteChain.RPC.call(chain, to: Base16.encode(to), data: data) do
        {:ok, ret} -> BnsMigrate.decode_eth_call_address(ret)
        {:error, error} -> {:error, error}
      end
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
    end
  end

  def call_address_array(chain, to, method) do
    case call_address_array_soft(chain, to, method) do
      {:ok, list} -> list
      {:error, error} -> raise "RPC error: #{inspect(error)} calling #{method}"
    end
  end

  def call_address_array_soft(chain, to, method) do
    data = ABI.encode_call(method, [], []) |> Base16.encode()

    try do
      case RemoteChain.RPC.call(chain, to: Base16.encode(to), data: data) do
        {:ok, ret} ->
          case BnsMigrate.decode_eth_call_address_array(ret) do
            {:ok, addrs} -> {:ok, Enum.reject(addrs, &null?/1)}
            {:error, _} = err -> err
          end

        {:error, error} ->
          {:error, error}
      end
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
    end
  end

  defp members_of_soft(chain, identity) do
    case memo_get({:members, chain, identity}) do
      {:ok, list} ->
        list

      :miss ->
        case call_address_array_soft(chain, identity, "Members") do
          {:ok, list} ->
            memo_put({:members, chain, identity}, list)

          {:error, error} ->
            BnsLog.puts("Members(#{Base16.encode(identity)}) reverted: #{inspect(error)}")
            []
        end
    end
  end

  def cache_put(slot, entry) do
    DetsPlus.insert(:base_cache, [{slot, entry}])
  end

  def cache_sync! do
    DetsPlus.sync(:base_cache)
  end

  def cache_done(slot, item) do
    base_dest = if item.action == :repair, do: item.repair_identity, else: item.v1_identity

    cache_put(
      slot,
      BnsMigrate.classify_cache_entry(%{
        item
        | action: nil,
          base_owner: item.owner,
          base_dest: base_dest,
          repair_deployed?: item.repair_deployed? or item.action == :repair,
          v1_deployed?: item.v1_deployed? or item.action in [:create, :resume_v1, :bns_v1]
      })
    )

    cache_sync!()
  end

  def deployer_nonce!(deployer) do
    rpc_retry!(fn ->
      RemoteChain.RPC.get_transaction_count(Chains.Base, Base16.encode(deployer))
      |> Base16.decode_int()
    end)
  end

  def ensure_and_maybe_register(wallet, salt, owner, fleet, deployer, name, nonce) do
    {identity, next_nonce} = ensure_identity(wallet, salt, owner, fleet, deployer, nonce)
    maybe_register_bns(wallet, name, identity, owner, next_nonce)
    identity
  end

  def maybe_register_bns(wallet, name, identity, owner, nonce) do
    base_dest = resolve_destination(name)
    base_owner = resolve_owner(name)

    if BnsMigrate.needs_bns_register?(base_owner, owner, base_dest, identity) do
      # Use the tracked nonce from ensure_identity — do not re-fetch eth_getTransactionCount
      # here (lagging Base RPCs caused "nonce too low" on Register after awaited sync txs).
      register_bns(wallet, name, identity, owner, nonce)
    else
      nonce
    end
  end

  @doc """
  Classify a single name for the parallel `Task.async_stream` loop.
  Returns a work tuple, or `nil` when there is nothing to do / on soft failure.

  When `dry_run: true`, also returns tuples for `action: nil` so the report
  still prints "No work." for fully migrated names.
  """
  def classify_one_name(name, storage, deployer, opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    try do
      owner_slot = BnsMigrate.owner_slot(name)

      owner =
        case Map.get(storage, owner_slot) do
          nil -> resolve_name_owner(name)
          owner_raw -> Hash.to_address(owner_raw)
        end

      if owner == nil or null?(owner) do
        BnsLog.puts("SKIP #{name}: could not resolve name owner")
        nil
      else
        case BnsMigrate.parse_classify_cache(DetsPlus.lookup(:base_cache, owner_slot)) do
          {:ok, %{action: nil} = entry} ->
            if dry_run?, do: work_from_cache_entry(name, owner, owner_slot, entry), else: nil

          {:ok, entry} ->
            work_from_cache_entry(name, owner, owner_slot, entry)

          status when status in [:stale, :miss] ->
            if status == :stale do
              BnsLog.puts("Cache status for #{name} is stale; re-resolving on-chain")
            else
              BnsLog.inspect({name, Base16.encode(owner)})
            end

            classify_and_cache(name, owner, owner_slot, deployer, dry_run?)

          {:error, other} ->
            BnsLog.puts("SKIP #{name}: unexpected base_cache entry #{inspect(other)}")
            nil
        end
      end
    rescue
      e ->
        BnsLog.puts("SKIP #{name}: classification failed: #{Exception.message(e)}")
        nil
    catch
      :exit, reason ->
        BnsLog.puts("SKIP #{name}: classification exited: #{inspect(reason)}")
        nil
    end
  end

  def work_from_cache_entry(name, owner, owner_slot, entry) do
    item = %{
      action: entry.action,
      name: name,
      owner: owner,
      fleet: entry.fleet,
      l1_identity: nil,
      current_identity:
        BnsMigrate.select_current_identity(
          entry.base_dest,
          not BnsMigrate.null_address?(entry.base_dest),
          entry.v1_identity,
          entry.v1_deployed?
        ),
      base_owner: entry.base_owner,
      base_dest: entry.base_dest,
      v1_identity: entry.v1_identity,
      v1_deployed?: entry.v1_deployed?,
      repair_identity: entry.repair_identity,
      repair_deployed?: entry.repair_deployed?,
      broken?: entry.action == :repair,
      repaired?: false
    }

    if entry.action == :repair do
      BnsLog.puts("REPAIR #{name}: cached -> #{Base16.encode(entry.repair_identity)}")
    end

    work_tuple(name, owner, owner_slot, item)
  end

  def classify_and_cache(name, owner, owner_slot, deployer, dry_run? \\ false) do
    # Local CREATE2 + batched getCode for v1/repair probes.
    [{v1_identity, v1_deployed?}, {repair_identity, repair_deployed?}] =
      identity_probes(owner)

    item =
      classify_work_item(
        name,
        owner,
        deployer,
        v1_identity,
        v1_deployed?,
        repair_identity,
        repair_deployed?
      )

    cache_put(owner_slot, BnsMigrate.classify_cache_entry(item))

    cond do
      item.action == :repair ->
        BnsLog.puts(
          "REPAIR #{name}: broken #{Base16.encode(item.current_identity)} (owner-only on Base, fleet on L1) -> #{Base16.encode(repair_identity)}"
        )

        work_tuple(name, owner, owner_slot, item)

      item.action != nil ->
        work_tuple(name, owner, owner_slot, item)

      dry_run? ->
        work_tuple(name, owner, owner_slot, item)

      true ->
        nil
    end
  end

  defp work_tuple(name, owner, owner_slot, item) do
    {item.action, name, owner, owner_slot, item.fleet, identity_salt(owner), item.v1_identity,
     repair_salt(owner), item.repair_identity, item}
  end

  def submit(wallet, to, method, types, args, nonce, retries \\ 30) do
    if retries == 0 do
      raise "Failed to submit transaction after retries exhausted"
    end

    tx =
      Shell.transaction(
        wallet,
        to,
        method,
        types,
        args,
        nonce: nonce,
        chainId: Chains.Base.chain_id()
      )

    case submit_tx(tx) do
      {:error, {:nonce_too_low, error}} ->
        Logger.error(
          "Nonce too low (#{inspect(error)}); re-signing with fresh nonce (attempted=#{nonce})"
        )

        Process.sleep(2_000)
        fresh = deployer_nonce!(Wallet.address!(wallet))
        next = BnsMigrate.next_submit_nonce(nonce, fresh)
        submit(wallet, to, method, types, args, next, retries - 1)

      ref ->
        {ref, nonce + 1}
    end
  end

  def create_identity(wallet, salt, nonce) do
    BnsLog.puts("TX: Create identity as deployer salt=#{Base16.encode(salt)} ...")

    submit(
      wallet,
      @factory,
      "Create",
      ["address", "bytes32", "address"],
      [Wallet.address!(wallet), salt, @drive_member],
      nonce
    )
  end

  @doc """
  While deployer still owns the identity: AddMember fleet, RemoveMember(deployer),
  transferOwnership(final_owner). Returns {next_nonce, tx_ids}.
  """
  def sync_members(wallet, identity, final_owner, fleet, deployer, nonce) do
    current_members = members_of(Chains.Base, identity)
    current_owner = owner_of(Chains.Base, identity)

    plan =
      BnsMigrate.sync_member_plan(current_members, fleet, deployer, final_owner, current_owner)

    {nonce, txs} =
      Enum.reduce(plan.add, {nonce, []}, fn member, {n, acc} ->
        BnsLog.puts("TX: AddMember #{Base16.encode(member)} ...")
        {id, n2} = submit(wallet, identity, "AddMember", ["address"], [member], n)
        {n2, [id | acc]}
      end)

    {nonce, txs} =
      if plan.remove_deployer? do
        BnsLog.puts("TX: RemoveMember deployer #{Base16.encode(deployer)} ...")
        {id, n2} = submit(wallet, identity, "RemoveMember", ["address"], [deployer], nonce)
        {n2, [id | txs]}
      else
        {nonce, txs}
      end

    {nonce, txs} =
      if plan.transfer? do
        BnsLog.puts("TX: transferOwnership -> #{Base16.encode(final_owner)} ...")

        {id, n2} =
          submit(wallet, identity, "transferOwnership", ["address"], [final_owner], nonce)

        {n2, [id | txs]}
      else
        {nonce, txs}
      end

    {nonce, txs}
  end

  @doc """
  Ensure identity at `salt` exists, is filled from `fleet`, and is owned by
  `final_owner`. Returns the identity address.
  """
  def ensure_identity(wallet, salt, final_owner, fleet, deployer, nonce) do
    {identity, deployed?} = identity_deployed?(salt)

    {nonce, txs} =
      cond do
        not deployed? ->
          {id, n} = create_identity(wallet, salt, nonce)
          await_txs([id])
          memo_put_deployed(salt, identity)
          {n2, member_txs} = sync_members(wallet, identity, final_owner, fleet, deployer, n)
          memo_invalidate_account_state(Chains.Base, identity)
          {n2, member_txs}

        true ->
          owner = owner_of(Chains.Base, identity)
          complete? = members_complete?(identity, fleet, deployer)

          cond do
            owner == deployer ->
              BnsLog.puts("TX: Sync members on #{Base16.encode(identity)} ...")

              {n, member_txs} =
                sync_members(wallet, identity, final_owner, fleet, deployer, nonce)

              memo_invalidate_account_state(Chains.Base, identity)
              {n, member_txs}

            not complete? ->
              raise "Identity #{Base16.encode(identity)} is incomplete but owned by #{Base16.encode(owner)}"

            true ->
              {nonce, []}
          end
      end

    if txs != [], do: await_txs(txs)
    {identity, nonce}
  end

  def register_bns(wallet, name, identity, final_owner, nonce) do
    BnsLog.puts("TX: Register #{name} -> #{Base16.encode(identity)} (BNSAdmin) ...")
    {id_reg, n} = submit(wallet, @bns, "Register", ["string", "address"], [name, identity], nonce)

    BnsLog.puts("TX: TransferOwner #{name} -> #{Base16.encode(final_owner)} ...")

    {id_own, n2} =
      submit(wallet, @bns, "TransferOwner", ["string", "address"], [name, final_owner], n)

    await_txs([id_own, id_reg])
    n2
  end

  def resolve_name_owner(name) do
    owner = diode_resolve_owner(name)

    cond do
      not null?(owner) ->
        owner

      true ->
        base_owner = resolve_owner(name)
        if null?(base_owner), do: nil, else: base_owner
    end
  end

  def classify_work_item(
        name,
        owner,
        deployer,
        v1_identity,
        v1_deployed?,
        repair_identity,
        repair_deployed?
      ) do
    [base_dest, base_owner, {fleet, l1_identity}] =
      parallel_map!([
        fn -> resolve_destination(name) end,
        fn -> resolve_owner(name) end,
        fn -> origin_fleet(name, owner) end
      ])

    base_dest_has_code? =
      not null?(base_dest) and has_code?(Chains.Base, base_dest)

    current_identity =
      BnsMigrate.select_current_identity(
        base_dest,
        base_dest_has_code?,
        v1_identity,
        v1_deployed?
      )

    broken? =
      if is_binary(current_identity) and is_binary(l1_identity) do
        base_code? =
          cond do
            current_identity == base_dest -> base_dest_has_code?
            current_identity == v1_identity -> v1_deployed?
            current_identity == repair_identity -> repair_deployed?
            true -> has_code?(Chains.Base, current_identity)
          end

        # origin_fleet only returns l1_identity when L1 dest had code.
        broken_identity?(current_identity, l1_identity, base_code?, true)
      else
        false
      end

    repair_complete? =
      repair_deployed? and members_complete?(repair_identity, fleet, deployer)

    repaired? =
      BnsMigrate.repaired?(
        repair_deployed?,
        base_dest,
        repair_identity,
        repair_complete?
      )

    bns_needs_v1? =
      BnsMigrate.bns_needs_v1?(broken?, repaired?, base_owner, owner, base_dest, v1_identity)

    v1_owned_by_deployer? =
      v1_deployed? and owner_of(Chains.Base, v1_identity) == deployer

    action =
      BnsMigrate.classify_repair_action(%{
        repaired?: repaired?,
        broken?: broken?,
        v1_deployed?: v1_deployed?,
        v1_owned_by_deployer?: v1_owned_by_deployer?,
        bns_needs_v1?: bns_needs_v1?
      })

    %{
      action: action,
      name: name,
      owner: owner,
      fleet: fleet,
      l1_identity: l1_identity,
      current_identity: current_identity,
      base_owner: base_owner,
      base_dest: base_dest,
      v1_identity: v1_identity,
      v1_deployed?: v1_deployed?,
      repair_identity: repair_identity,
      repair_deployed?: repair_deployed?,
      broken?: broken?,
      repaired?: repaired?
    }
  end

  def print_dry_run(item, deployer) do
    chain_state =
      case item.action do
        :repair when item.repair_deployed? ->
          %{
            members: members_of(Chains.Base, item.repair_identity),
            owner: owner_of(Chains.Base, item.repair_identity)
          }

        :resume_v1 when item.v1_deployed? ->
          %{
            members: members_of(Chains.Base, item.v1_identity),
            owner: owner_of(Chains.Base, item.v1_identity)
          }

        _ ->
          %{}
      end

    BnsLog.puts(BnsMigrate.format_dry_run(item, deployer, chain_state))
  end
end

# curl -k -H "Content-Type: application/json" -X POST --data '{"jsonrpc":"2.0","method":"eth_getStorage","params":["0xaf60faa5cd840b724742f1af116168276112d6a6", "latest"],"id":73}' https://prenet.diode.io:8443 > bns_2026_08_01.json

storage =
  File.read!("bns_2026_08_01.json")
  |> Poison.decode!()
  |> Map.get("result")
  |> Enum.map(fn
    [key, "0x" <> _ = value] -> {Base16.decode(key), Base16.decode(value)}
    _ -> {nil, nil}
  end)
  |> Enum.reject(fn
    {nil, nil} -> true
    _ -> false
  end)
  |> Map.new()

names =
  Enum.map(storage, fn {_key, <<str::binary-size(31), len2>>} ->
    str = String.trim_trailing(str, "\0")

    if len2 == byte_size(str) * 2 do
      str
    else
      "\0"
    end
  end)
  |> Enum.filter(fn name ->
    String.printable?(name) and not String.contains?(name, "satanmeth") and
      not String.starts_with?(name, "diodetest") and
      not String.starts_with?(name, "test-") and
      not String.starts_with?(name, "drive-")
  end)
  |> Enum.sort()
  |> Enum.uniq()

{names, missing} = BnsMigrate.apply_name_filter(names, only_names)

if missing != [] do
  BnsLog.puts("Names not in dump (owner will be resolved on-chain): #{Enum.join(missing, ", ")}")
end

{names, invalid_names} = BnsMigrate.partition_valid_names(names)

Enum.each(invalid_names, fn name ->
  BnsLog.puts(
    "SKIP #{name}: invalid Base BNS name (need 8-32 chars of [0-9a-z-], no leading/trailing '-')"
  )
end)

if only_names != [] do
  BnsLog.puts("Filter: #{Enum.join(only_names, ", ")}")
end

if dry_run do
  BnsLog.puts("Mode: dry-run (no transactions)")
end

BnsLog.puts("Names: #{length(names)} (skipped invalid: #{length(invalid_names)})")
{:ok, _dets} = DetsPlus.open_file(:base_cache)
Helper.init_memo!()

stale_keys =
  DetsPlus.reduce(:base_cache, [], fn {key, value}, acc ->
    if BnsMigrate.stale_classify_cache_value?(value), do: [key | acc], else: acc
  end)

if stale_keys != [] do
  Enum.each(stale_keys, &DetsPlus.delete(:base_cache, &1))
  Helper.cache_sync!()
  BnsLog.puts("Purged #{length(stale_keys)} stale base_cache entr(y/ies) (legacy atom/tuple)")
end

wallet = Wallet.from_privkey(Base16.decode(String.trim(File.read!("diode_glmr.key"))))
deployer = Wallet.address!(wallet)

if deployer != Helper.bns_admin() do
  raise "diode_glmr.key must be BNSAdmin #{Base16.encode(Helper.bns_admin())}, got #{Base16.encode(deployer)}"
end

classify_concurrency =
  BnsMigrate.classify_concurrency(System.get_env("BNS_CLASSIFY_CONCURRENCY"))

Helper.await_chains_ready!()
BnsLog.puts("Classifying #{length(names)} names (concurrency=#{classify_concurrency}) ...")

work =
  names
  |> Task.async_stream(
    fn name -> Helper.classify_one_name(name, storage, deployer, dry_run: dry_run) end,
    max_concurrency: classify_concurrency,
    timeout: :infinity,
    ordered: false,
    on_timeout: :kill_task
  )
  |> Enum.flat_map(fn
    {:ok, nil} ->
      []

    {:ok, item} ->
      [item]

    {:exit, reason} ->
      BnsLog.puts("SKIP classification task exited: #{inspect(reason)}")
      []
  end)

Helper.cache_sync!()

{repairs, _other} =
  Enum.split_with(work, fn {action, _, _, _, _, _, _, _, _, _} -> action == :repair end)

BnsLog.puts("Work: #{length(work)} (repairs=#{length(repairs)})")

if dry_run do
  Enum.each(work, fn {_action, _name, _owner, _slot, _fleet, _v1_salt, _v1_id, _r_salt, _r_id,
                      item} ->
    try do
      Helper.print_dry_run(item, deployer)
    rescue
      e ->
        BnsLog.puts("DRY-RUN #{item.name} failed: #{Exception.message(e)}")
    catch
      :exit, reason ->
        BnsLog.puts("DRY-RUN #{item.name} exited: #{inspect(reason)}")
    end
  end)

  BnsLog.puts("\nDone (dry-run). #{length(work)} item(s).")
else
  work =
    Enum.shuffle(work)
    |> Enum.chunk_every(1)

  for chunk <- work do
    Enum.each(
      chunk,
      fn {action, name, owner, slot, fleet, v1_salt, v1_identity, repair_salt, _repair_identity,
          item} ->
        try do
          balance = Helper.ensure_gas!(wallet)
          BnsLog.puts("Wallet: #{Base16.encode(deployer)} Balance: #{balance}")

          Process.sleep(100)
          DetsPlus.delete(:base_cache, slot)
          Helper.cache_sync!()

          nonce = Helper.deployer_nonce!(deployer)

          BnsLog.puts(
            "Prepare #{name} action=#{action} owner=#{Base16.encode(owner)} fleet=#{length(fleet)} ..."
          )

          case action do
            :repair ->
              Helper.ensure_and_maybe_register(
                wallet,
                repair_salt,
                owner,
                fleet,
                deployer,
                name,
                nonce
              )

            action when action in [:create, :resume_v1] ->
              Helper.ensure_and_maybe_register(
                wallet,
                v1_salt,
                owner,
                fleet,
                deployer,
                name,
                nonce
              )

            :bns_v1 ->
              Helper.register_bns(wallet, name, v1_identity, owner, nonce)
          end

          Helper.cache_done(slot, item)
        rescue
          e ->
            message = Exception.message(e)

            if String.contains?(String.downcase(message), "out of gas") or
                 String.contains?(String.downcase(message), "insufficient funds") do
              # Fatal for the whole run — do not continue burning through names.
              reraise e, __STACKTRACE__
            end

            BnsLog.puts("FAIL #{name}: #{message}")
        catch
          :exit, reason ->
            BnsLog.puts("FAIL #{name}: exited #{inspect(reason)}")
        end
      end
    )
  end
end
