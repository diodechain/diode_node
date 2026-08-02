# Diode Server
# Copyright 2021-2026 Diode
# Licensed under the Diode License, Version 1.1

defmodule Script.BnsMigrate do
  @moduledoc """
  Pure helpers for Base BNS name migration / repair (see `scripts/bns.exs`).
  """

  alias DiodeClient.Hash

  @type address :: binary()
  @type cache_tuple :: {address(), boolean(), address(), address()}
  @type classification :: :done | :owner_controlled | :foreign_owner | :migratable
  @type cache_status ::
          :invalid | :done | :foreign_owner | :owner_controlled | {:partial, cache_tuple()}
  @type repair_action :: :repair | :create | :resume_v1 | :bns_v1

  # 1 finney == 0.001 ether
  @min_gas_wei 1_000_000_000_000_000

  def zero_address, do: Hash.to_address(0)

  def min_gas_wei, do: @min_gas_wei

  def sufficient_gas?(balance) when is_integer(balance), do: balance >= @min_gas_wei

  @doc """
  Argument shape required by `Shell.await_tx_id/1`.

  Passing a bare tx_id binary raises FunctionClauseError because the clause is
  `await_tx_id({tx_id, tx}, n \\\\ 0)` — the transaction is needed for chain_id
  and resubmit. See `scripts/bns.exs` submit/await path.
  """
  def await_tx_ref(tx_id, tx) when is_binary(tx_id), do: {tx_id, tx}

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
