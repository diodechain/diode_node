# Diode Server
# Copyright 2021-2026 Diode
# Licensed under the Diode License, Version 1.1

defmodule Script.BnsMigrate do
  @moduledoc """
  Pure helpers for Base BNS name migration (see `scripts/bns.exs`).
  """

  alias DiodeClient.Hash

  @type address :: binary()
  @type cache_tuple :: {address(), boolean(), address(), address()}
  @type classification :: :done | :owner_controlled | :foreign_owner | :migratable
  @type cache_status ::
          :invalid | :done | :foreign_owner | :owner_controlled | {:partial, cache_tuple()}

  def zero_address, do: Hash.to_address(0)

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
