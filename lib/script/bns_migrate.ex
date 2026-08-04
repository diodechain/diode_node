# Diode Server
# Copyright 2021-2026 Diode
# Licensed under the Diode License, Version 1.1

defmodule Script.BnsMigrate do
  @moduledoc """
  Pure helpers for Base BNS name migration / repair (see `scripts/bns.exs`).
  """

  alias DiodeClient.{ABI, Base16, Hash}
  alias DiodeClient.Contracts.Factory

  @type address :: binary()
  @type cache_tuple :: {address(), boolean(), address(), address()}
  @type classification :: :done | :owner_controlled | :foreign_owner | :migratable
  @type cache_status ::
          :invalid | :done | :foreign_owner | :owner_controlled | {:partial, cache_tuple()}
  @type repair_action :: :repair | :create | :resume_v1 | :bns_v1
  @type classify_cache_entry :: %{
          v: 2,
          v1_identity: address(),
          v1_deployed?: boolean(),
          repair_identity: address(),
          repair_deployed?: boolean(),
          base_owner: address(),
          base_dest: address(),
          fleet: [address()],
          action: repair_action() | nil
        }

  # 1 finney == 0.001 ether
  @min_gas_wei 1_000_000_000_000_000
  @classify_cache_v 2
  # Keep classify concurrency modest: each name fans out nested eth_calls.
  @default_classify_concurrency 4
  @rate_limit_reconnect_ms 15_000

  def zero_address, do: Hash.to_address(0)

  def min_gas_wei, do: @min_gas_wei

  def classify_cache_version, do: @classify_cache_v

  def rate_limit_reconnect_ms, do: @rate_limit_reconnect_ms

  def sufficient_gas?(balance) when is_integer(balance), do: balance >= @min_gas_wei

  def default_classify_concurrency, do: @default_classify_concurrency

  @doc """
  Parse `BNS_CLASSIFY_CONCURRENCY` (or any integer string). Invalid / missing → default.
  Clamped to 1..64 so a typo cannot spawn thousands of tasks.
  """
  def classify_concurrency(nil), do: @default_classify_concurrency

  def classify_concurrency(value) when is_integer(value) do
    value |> max(1) |> min(64)
  end

  def classify_concurrency(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> classify_concurrency(n)
      _ -> @default_classify_concurrency
    end
  end

  def classify_concurrency(_), do: @default_classify_concurrency

  @doc """
  Diode L1 BNS owner storage slot for a name (slot 1 mapping + 1).
  """
  def owner_slot(name) when is_binary(name) do
    name_hash = Hash.keccak_256(name)
    base = Hash.to_bytes32(1)

    Hash.keccak_256(name_hash <> base)
    |> :binary.decode_unsigned()
    |> Kernel.+(1)
    |> :binary.encode_unsigned()
  end

  @doc """
  Argument shape required by `Shell.await_tx_id/1`.

  Passing a bare tx_id binary raises FunctionClauseError because the clause is
  `await_tx_id({tx_id, tx}, n \\\\ 0)` — the transaction is needed for chain_id
  and resubmit. See `scripts/bns.exs` submit/await path.
  """
  def await_tx_ref(tx_id, tx) when is_binary(tx_id), do: {tx_id, tx}

  @doc """
  Detect provider "nonce too low" rejections from varied error shapes.
  """
  def nonce_too_low_error?(error) do
    message =
      cond do
        is_binary(error) ->
          error

        is_atom(error) ->
          Atom.to_string(error)

        is_exception(error) ->
          Exception.message(error)

        is_map(error) ->
          "#{Map.get(error, :message, Map.get(error, "message", ""))} #{inspect(error)}"

        true ->
          inspect(error)
      end
      |> String.downcase()

    String.contains?(message, "nonce too low")
  end

  @doc """
  Choose the next nonce after a "nonce too low" rejection.

  Prefers `max(attempted + 1, fetched)` so a lagging `eth_getTransactionCount`
  cannot keep us pinned on the rejected nonce.
  """
  def next_submit_nonce(attempted_nonce, fetched_nonce)
      when is_integer(attempted_nonce) and is_integer(fetched_nonce) and attempted_nonce >= 0 and
             fetched_nonce >= 0 do
    max(attempted_nonce + 1, fetched_nonce)
  end

  @doc """
  Decode an `eth_call` hex/binary result as a single address.

  Empty `"0x"` / undersized payloads (common when the account has no code) become
  `{:error, :empty_result}` instead of raising in `DiodeClient.ABI` / `Hash`.
  """
  def decode_eth_call_address(hex_or_bin) when is_binary(hex_or_bin) do
    case normalize_call_data(hex_or_bin) do
      {:ok, <<word::binary-size(32), _::binary>>} -> {:ok, Hash.to_address(word)}
      _ -> {:error, :empty_result}
    end
  end

  @doc """
  Decode an `eth_call` hex/binary result as `address[]`.

  Empty `"0x"` is the production crash shape (`Invalid value for type uint256: "0x"`).
  """
  def decode_eth_call_address_array(hex_or_bin) when is_binary(hex_or_bin) do
    case normalize_call_data(hex_or_bin) do
      {:ok, data} when byte_size(data) >= 32 ->
        try do
          case ABI.decode_args(["address[]"], data) do
            [addrs] when is_list(addrs) -> {:ok, addrs}
            _ -> {:error, :empty_result}
          end
        rescue
          RuntimeError -> {:error, :empty_result}
        end

      _ ->
        {:error, :empty_result}
    end
  end

  defp normalize_call_data("0x"), do: {:error, :empty_result}
  defp normalize_call_data(""), do: {:error, :empty_result}

  defp normalize_call_data(<<"0x", _::binary>> = hex) do
    try do
      {:ok, Base16.decode(hex)}
    rescue
      _ -> {:error, :empty_result}
    end
  end

  defp normalize_call_data(bin) when is_binary(bin), do: {:ok, bin}

  @doc """
  Build a v2 classification cache entry used to skip RPC on restart.
  """
  def classify_cache_entry(attrs) when is_map(attrs) do
    %{
      v: @classify_cache_v,
      v1_identity: Map.fetch!(attrs, :v1_identity),
      v1_deployed?: Map.fetch!(attrs, :v1_deployed?),
      repair_identity: Map.fetch!(attrs, :repair_identity),
      repair_deployed?: Map.fetch!(attrs, :repair_deployed?),
      base_owner: Map.fetch!(attrs, :base_owner),
      base_dest: Map.fetch!(attrs, :base_dest),
      fleet: Map.fetch!(attrs, :fleet),
      action: Map.get(attrs, :action)
    }
  end

  @doc """
  Parse a `:base_cache` DetsPlus.lookup/2 result for repair classification.

  v2 maps are reusable without RPC. Legacy identity tuples and migrator atom
  statuses are `:stale` so callers re-resolve on-chain.
  """
  def parse_classify_cache([{_slot, %{v: @classify_cache_v} = entry}]) do
    if valid_classify_cache_entry?(entry) do
      {:ok, entry}
    else
      {:error, entry}
    end
  end

  def parse_classify_cache([{_slot, status}]) when is_atom(status), do: :stale

  def parse_classify_cache([{_slot, cached}])
      when is_tuple(cached) and tuple_size(cached) >= 2 and is_binary(elem(cached, 0)) and
             is_boolean(elem(cached, 1)) do
    :stale
  end

  def parse_classify_cache([]), do: :miss
  def parse_classify_cache(other), do: {:error, other}

  @doc """
  Legacy atom/tuple `:base_cache` values (pre-v2) that force a full reclassify.
  """
  def stale_classify_cache_value?(%{v: @classify_cache_v} = entry),
    do: not valid_classify_cache_entry?(entry)

  def stale_classify_cache_value?(value) when is_atom(value), do: true

  def stale_classify_cache_value?(value)
      when is_tuple(value) and tuple_size(value) >= 2 and is_binary(elem(value, 0)) and
             is_boolean(elem(value, 1)),
      do: true

  def stale_classify_cache_value?(_), do: true

  @doc """
  Keys whose cached values are stale and should be deleted once at startup so
  restarts do not repeatedly log/re-parse legacy atoms.
  """
  def collect_stale_cache_keys(entries) when is_list(entries) do
    for {key, value} <- entries, stale_classify_cache_value?(value), do: key
  end

  defp valid_classify_cache_entry?(%{
         v: @classify_cache_v,
         v1_identity: v1,
         v1_deployed?: v1d,
         repair_identity: r,
         repair_deployed?: rd,
         base_owner: bo,
         base_dest: bd,
         fleet: fleet,
         action: action
       })
       when is_binary(v1) and is_boolean(v1d) and is_binary(r) and is_boolean(rd) and
              is_binary(bo) and is_binary(bd) and is_list(fleet) and
              (is_nil(action) or action in [:repair, :create, :resume_v1, :bns_v1]) do
    Enum.all?(fleet, &is_binary/1)
  end

  defp valid_classify_cache_entry?(_), do: false

  @doc """
  Parse a `:base_cache` DetsPlus.lookup/2 result for the v1 identity tuple.

  Atom statuses (`:done`, `:foreign_owner`, …) come from the older Create/Register
  migrator and are treated as stale for repair — callers must re-resolve on-chain.
  """
  def parse_identity_cache([{_slot, {identity, deployed?, _base_owner, _base_dest}}])
      when is_binary(identity) and is_boolean(deployed?) do
    {:ok, identity, deployed?}
  end

  def parse_identity_cache([{_slot, cached}])
      when is_tuple(cached) and tuple_size(cached) >= 2 and is_binary(elem(cached, 0)) and
             is_boolean(elem(cached, 1)) do
    {:ok, elem(cached, 0), elem(cached, 1)}
  end

  def parse_identity_cache([{_slot, status}]) when is_atom(status), do: :stale
  def parse_identity_cache([]), do: :miss
  def parse_identity_cache(other), do: {:error, other}

  @doc """
  Mirror Base BNS `validate()` — names that fail this revert on Resolve/Register.
  Length 8..32, charset `[0-9a-z-]`, no leading/trailing `-`.
  """
  def valid_bns_name?(name) when is_binary(name) do
    len = byte_size(name)

    len > 7 and len <= 32 and
      not String.starts_with?(name, "-") and
      not String.ends_with?(name, "-") and
      Regex.match?(~r/^[0-9a-z-]+$/, name)
  end

  def valid_bns_name?(_), do: false

  @doc """
  Partition names into `{valid, invalid}` using `valid_bns_name?/1`.
  """
  def partition_valid_names(names) when is_list(names) do
    Enum.split_with(names, &valid_bns_name?/1)
  end

  @doc """
  Parse CLI argv. Recognizes `--dry-run`. Any other flag starting with `-` is an error.
  Remaining args are raw name filters (normalize with `normalize_name/1`).
  """
  def parse_argv(argv) when is_list(argv) do
    {flags, names} = Enum.split_with(argv, &String.starts_with?(&1, "-"))
    unknown = flags -- ["--dry-run"]

    if unknown != [] do
      {:error, {:unknown_args, unknown}}
    else
      {:ok, %{dry_run: "--dry-run" in flags, names: names}}
    end
  end

  def normalize_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> String.replace_suffix(".diode", "")
    |> String.replace_suffix(".base", "")
    |> String.replace_suffix(".glmr", "")
    |> String.replace_suffix(".sapphire", "")
  end

  @doc """
  Apply optional name filter. Returns `{selected_names, missing_from_dump}`.
  Names not in the dump are appended so callers can resolve owners on-chain.
  """
  def apply_name_filter(all_names, only_names) when is_list(all_names) and is_list(only_names) do
    case only_names do
      [] ->
        {all_names, []}

      only ->
        filtered = Enum.filter(all_names, &(&1 in only))
        missing = only -- filtered
        {filtered ++ missing, missing}
    end
  end

  def null_address?(address, null \\ zero_address()) do
    address == nil or address == null
  end

  def identity_salt(owner) when is_binary(owner), do: Hash.keccak_256(owner)

  def repair_salt(owner) when is_binary(owner), do: Hash.keccak_256("bns-repair-v1" <> owner)

  @doc """
  Local CREATE2 for Base DriveFactory proxies — avoids `Create2Address` eth_call.
  """
  def base_create2_address(salt) when is_binary(salt) and byte_size(salt) == 32 do
    c = Factory.contracts(DiodeClient.Shell.Base)
    Hash.create2(c.factory, c.proxy_code_hash, salt)
  end

  @doc """
  Detect provider rate-limit / 429 errors from varied exception/error shapes.
  """
  def rate_limit_error?(error) do
    message =
      cond do
        is_binary(error) ->
          error

        is_atom(error) ->
          Atom.to_string(error)

        is_exception(error) ->
          Exception.message(error)

        is_map(error) ->
          "#{Map.get(error, :message, Map.get(error, "message", ""))} #{inspect(error)}"

        true ->
          inspect(error)
      end
      |> String.downcase()

    String.contains?(message, "429") or String.contains?(message, "too many requests")
  end

  @doc """
  Backoff for classify RPC retries. Rate-limited paths wait much longer so we
  do not amplify 429 reconnect storms.
  """
  def rpc_backoff_ms(retries_left, rate_limited? \\ false)
      when is_integer(retries_left) and retries_left >= 0 do
    base = if rate_limited?, do: 5_000, else: 1_000
    min(30_000, base * max(1, 6 - retries_left))
  end

  def select_current_identity(base_dest, base_dest_has_code?, v1_identity, v1_deployed?) do
    cond do
      not null_address?(base_dest) and base_dest_has_code? -> base_dest
      v1_deployed? -> v1_identity
      true -> nil
    end
  end

  @doc """
  Compose the fleet to seed onto Base from the Diode L1 identity owner/members.

  When `id_owner` is nil (no L1 code, or `owner()` eth_call reverted), fall back
  to the BNS name owner only and treat L1 identity as unavailable.
  """
  def build_origin_fleet(bns_owner, nil, _members, _dest) when is_binary(bns_owner) do
    {[bns_owner], nil}
  end

  def build_origin_fleet(bns_owner, id_owner, members, dest)
      when is_binary(bns_owner) and is_binary(id_owner) and is_list(members) and is_binary(dest) do
    fleet =
      [id_owner, bns_owner | members]
      |> Enum.reject(&null_address?/1)
      |> Enum.uniq()

    {fleet, dest}
  end

  @doc """
  Broken = Base identity has code but no non-owner members, while the L1 counterpart
  has at least one non-owner member (fleet was never copied).
  """
  def broken_identity?(base_has_code?, l1_has_code?, base_non_owners, l1_non_owners)
      when is_list(base_non_owners) and is_list(l1_non_owners) do
    base_has_code? and l1_has_code? and base_non_owners == [] and l1_non_owners != []
  end

  def members_complete?(actual_members, fleet, deployer)
      when is_list(actual_members) and is_list(fleet) do
    actual = MapSet.new(actual_members)
    expected = MapSet.new(fleet)

    MapSet.subset?(expected, actual) and
      (deployer in fleet or not MapSet.member?(actual, deployer))
  end

  def repaired?(repair_deployed?, base_dest, repair_identity, members_complete?) do
    repair_deployed? and base_dest == repair_identity and members_complete?
  end

  def bns_needs_v1?(broken?, repaired?, base_owner, owner, base_dest, v1_identity) do
    not broken? and not repaired? and
      (null_address?(base_owner) or base_owner != owner or base_dest != v1_identity)
  end

  @doc """
  Decide the migration/repair action from precomputed boolean flags.
  """
  def classify_repair_action(%{
        repaired?: repaired?,
        broken?: broken?,
        v1_deployed?: v1_deployed?,
        v1_owned_by_deployer?: v1_owned_by_deployer?,
        bns_needs_v1?: bns_needs_v1?
      }) do
    cond do
      repaired? -> nil
      broken? -> :repair
      not v1_deployed? -> :create
      v1_owned_by_deployer? -> :resume_v1
      bns_needs_v1? -> :bns_v1
      true -> nil
    end
  end

  def needs_bns_register?(base_owner, owner, base_dest, identity) do
    null_address?(base_owner) or base_owner != owner or base_dest != identity
  end

  @doc """
  Format a `--dry-run` report for one classified work item without submitting txs.

  `chain_state` may include `:members` / `:owner` for the identity that would be
  synced (`:repair` or `:resume_v1`). When omitted, assumes empty members and
  deployer ownership (typical for `:create`).
  """
  def format_dry_run(item, deployer, chain_state \\ %{})
      when is_map(item) and is_binary(deployer) and is_map(chain_state) do
    %{
      action: action,
      name: name,
      owner: owner,
      fleet: fleet,
      current_identity: current_identity,
      base_owner: base_owner,
      base_dest: base_dest,
      v1_identity: v1_identity,
      v1_deployed?: v1_deployed?,
      repair_identity: repair_identity,
      repair_deployed?: repair_deployed?,
      broken?: broken?,
      repaired?: repaired?,
      l1_identity: l1_identity
    } = item

    header = [
      "",
      "=== DRY-RUN #{name} ===",
      "action: #{inspect(action)}",
      "owner: #{Base16.encode(owner)}",
      "base_owner: #{fmt_addr(base_owner)}",
      "base_dest: #{fmt_addr(base_dest)}",
      "current_identity: #{fmt_addr(current_identity)}",
      "l1_identity: #{fmt_addr(l1_identity)}",
      "broken?: #{broken?} repaired?: #{repaired?}",
      "v1: #{Base16.encode(v1_identity)} deployed?=#{v1_deployed?}",
      "repair: #{Base16.encode(repair_identity)} deployed?=#{repair_deployed?}",
      "fleet (#{length(fleet)}):"
    ]

    fleet_lines = Enum.map(fleet, fn addr -> "  #{Base16.encode(addr)}" end)

    body =
      case action do
        :repair ->
          format_identity_plan_lines(
            "repair",
            repair_identity,
            repair_deployed?,
            owner,
            fleet,
            deployer,
            chain_state
          ) ++ format_bns_plan_lines(name, repair_identity, owner, base_owner, base_dest)

        :create ->
          format_identity_plan_lines("v1", v1_identity, false, owner, fleet, deployer, %{}) ++
            format_bns_plan_lines(name, v1_identity, owner, base_owner, base_dest)

        :resume_v1 ->
          format_identity_plan_lines(
            "v1",
            v1_identity,
            true,
            owner,
            fleet,
            deployer,
            chain_state
          ) ++ format_bns_plan_lines(name, v1_identity, owner, base_owner, base_dest)

        :bns_v1 ->
          format_bns_plan_lines(name, v1_identity, owner, base_owner, base_dest)

        nil ->
          ["No work."]

        other ->
          ["Unknown action: #{inspect(other)}"]
      end

    Enum.join(header ++ fleet_lines ++ body, "\n")
  end

  defp format_identity_plan_lines(
         label,
         identity,
         deployed?,
         owner,
         fleet,
         deployer,
         chain_state
       ) do
    current_members = Map.get(chain_state, :members, [])
    current_owner = Map.get(chain_state, :owner, deployer)
    plan = sync_member_plan(current_members, fleet, deployer, owner, current_owner)
    add_lines = Enum.map(plan.add, fn a -> "        - #{Base16.encode(a)}" end)

    [
      "",
      "Would #{if deployed?, do: "sync", else: "create+sync"} #{label} identity #{Base16.encode(identity)}:",
      "  Create?=#{not deployed?}",
      "  AddMember x#{length(plan.add)}"
    ] ++
      add_lines ++
      [
        "  RemoveMember(deployer)?=#{plan.remove_deployer?}",
        "  transferOwnership(#{Base16.encode(owner)})?=#{plan.transfer?}",
        ""
      ]
  end

  defp format_bns_plan_lines(name, identity, owner, base_owner, base_dest) do
    if needs_bns_register?(base_owner, owner, base_dest, identity) do
      [
        "",
        "Would update BNS:",
        "  Register(\"#{name}\", #{Base16.encode(identity)})",
        "  TransferOwner(\"#{name}\", #{Base16.encode(owner)})",
        ""
      ]
    else
      [
        "BNS already points at #{Base16.encode(identity)} owned by #{Base16.encode(owner)}"
      ]
    end
  end

  defp fmt_addr(nil), do: "nil"

  defp fmt_addr(addr) do
    if null_address?(addr), do: "nil", else: Base16.encode(addr)
  end

  @doc """
  Plan member sync while deployer still owns the identity.
  """
  def sync_member_plan(current_members, fleet, deployer, final_owner, current_owner)
      when is_list(current_members) and is_list(fleet) do
    current = MapSet.new(current_members)

    to_add =
      fleet
      |> Enum.reject(&(null_address?(&1) or &1 == deployer or MapSet.member?(current, &1)))
      |> Enum.uniq()

    remove_deployer? =
      deployer != final_owner and MapSet.member?(current, deployer) and deployer not in fleet

    transfer? = current_owner == deployer and deployer != final_owner

    %{add: to_add, remove_deployer?: remove_deployer?, transfer?: transfer?}
  end

  @doc """
  Classify a name's Base BNS state relative to the L1 owner and deployer wallet.
  """
  def classify_name(deployer, owner, identity, base_owner, base_dest) do
    cond do
      base_owner == owner and base_dest == identity ->
        :done

      base_owner == owner and base_dest != identity ->
        # L1 owner already controls the name; deployer cannot update destination.
        :owner_controlled

      base_owner != zero_address() and base_owner != deployer ->
        # Registered by someone else on Base.
        :foreign_owner

      true ->
        # Unregistered or still owned by deployer — safe to migrate.
        :migratable
    end
  end

  @doc """
  Whether a migratable name still needs Create / Register / TransferOwner work.
  """
  def needs_migration_work?(owner, identity, deployed?, base_owner, base_dest) do
    not deployed? or base_owner != owner or base_dest != identity
  end

  @doc """
  Cache value after a Create/Register/TransferOwner failure, given fresh chain state.

  Never returns `:invalid` — that is reserved for resolve failures.
  Migratable partial progress is stored as `{:partial, tuple}` so re-runs can finish.
  """
  def cache_after_failure(deployer, owner, identity, deployed?, base_owner, base_dest) do
    tuple = {identity, deployed?, base_owner, base_dest}

    case classify_name(deployer, owner, identity, base_owner, base_dest) do
      :done -> :done
      :foreign_owner -> :foreign_owner
      :owner_controlled -> :owner_controlled
      :migratable -> {:partial, tuple}
    end
  end

  @doc """
  Whether a previously `:invalid` cache entry should be retried given a fresh classification.
  """
  def should_retry_invalid?(:migratable), do: true
  def should_retry_invalid?(_), do: false
end
