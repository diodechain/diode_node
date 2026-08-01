# Diode Server
# Copyright 2021-2026 Diode
# Licensed under the Diode License, Version 1.1

defmodule Script.BnsMigrateTest do
  use ExUnit.Case, async: true

  alias DiodeClient.Hash
  alias Script.BnsMigrate

  defp addr(n), do: Hash.to_address(n)

  setup do
    deployer = addr(1)
    owner = addr(2)
    identity = addr(3)
    foreign = addr(4)
    zero = BnsMigrate.zero_address()

    {:ok, deployer: deployer, owner: owner, identity: identity, foreign: foreign, zero: zero}
  end

  describe "classify_name/5" do
    test "done when L1 owner controls name and dest matches identity", ctx do
      assert :done =
               BnsMigrate.classify_name(
                 ctx.deployer,
                 ctx.owner,
                 ctx.identity,
                 ctx.owner,
                 ctx.identity
               )
    end

    test "owner_controlled when L1 owner owns but dest is wrong", ctx do
      assert :owner_controlled =
               BnsMigrate.classify_name(
                 ctx.deployer,
                 ctx.owner,
                 ctx.identity,
                 ctx.owner,
                 ctx.foreign
               )
    end

    test "foreign_owner when someone else owns on Base", ctx do
      assert :foreign_owner =
               BnsMigrate.classify_name(
                 ctx.deployer,
                 ctx.owner,
                 ctx.identity,
                 ctx.foreign,
                 ctx.identity
               )
    end

    test "migratable when unregistered", ctx do
      assert :migratable =
               BnsMigrate.classify_name(
                 ctx.deployer,
                 ctx.owner,
                 ctx.identity,
                 ctx.zero,
                 ctx.zero
               )
    end

    test "migratable when still owned by deployer with correct dest", ctx do
      assert :migratable =
               BnsMigrate.classify_name(
                 ctx.deployer,
                 ctx.owner,
                 ctx.identity,
                 ctx.deployer,
                 ctx.identity
               )
    end
  end

  describe "needs_migration_work?/5" do
    test "false when fully migrated", ctx do
      refute BnsMigrate.needs_migration_work?(
               ctx.owner,
               ctx.identity,
               true,
               ctx.owner,
               ctx.identity
             )
    end

    test "true when identity not deployed", ctx do
      assert BnsMigrate.needs_migration_work?(
               ctx.owner,
               ctx.identity,
               false,
               ctx.zero,
               ctx.zero
             )
    end

    test "true when deployer still owns after register", ctx do
      assert BnsMigrate.needs_migration_work?(
               ctx.owner,
               ctx.identity,
               true,
               ctx.deployer,
               ctx.identity
             )
    end
  end

  describe "cache_after_failure/6" do
    test "partial tuple when deployer owns identity dest after failed TransferOwner", ctx do
      result =
        BnsMigrate.cache_after_failure(
          ctx.deployer,
          ctx.owner,
          ctx.identity,
          true,
          ctx.deployer,
          ctx.identity
        )

      assert result == {:partial, {ctx.identity, true, ctx.deployer, ctx.identity}}
    end

    test "does not return invalid for migratable chain state", ctx do
      result =
        BnsMigrate.cache_after_failure(
          ctx.deployer,
          ctx.owner,
          ctx.identity,
          true,
          ctx.deployer,
          ctx.identity
        )

      assert match?({:partial, _}, result)
    end

    test "done when chain already matches L1 owner", ctx do
      assert :done =
               BnsMigrate.cache_after_failure(
                 ctx.deployer,
                 ctx.owner,
                 ctx.identity,
                 true,
                 ctx.owner,
                 ctx.identity
               )
    end

    test "foreign_owner when another address owns", ctx do
      assert :foreign_owner =
               BnsMigrate.cache_after_failure(
                 ctx.deployer,
                 ctx.owner,
                 ctx.identity,
                 true,
                 ctx.foreign,
                 ctx.identity
               )
    end

    test "owner_controlled when L1 owner has wrong dest", ctx do
      assert :owner_controlled =
               BnsMigrate.cache_after_failure(
                 ctx.deployer,
                 ctx.owner,
                 ctx.identity,
                 true,
                 ctx.owner,
                 ctx.foreign
               )
    end
  end

  describe "should_retry_invalid?/1" do
    test "retries migratable prior invalid entries" do
      assert BnsMigrate.should_retry_invalid?(:migratable)
    end

    test "does not retry terminal classifications" do
      refute BnsMigrate.should_retry_invalid?(:done)
      refute BnsMigrate.should_retry_invalid?(:foreign_owner)
      refute BnsMigrate.should_retry_invalid?(:owner_controlled)
      refute BnsMigrate.should_retry_invalid?(:invalid)
    end

    test "recovery path: prior invalid + deployer-owned partial is retryable", ctx do
      classified =
        BnsMigrate.classify_name(
          ctx.deployer,
          ctx.owner,
          ctx.identity,
          ctx.deployer,
          ctx.identity
        )

      assert classified == :migratable
      assert BnsMigrate.should_retry_invalid?(classified)

      assert BnsMigrate.needs_migration_work?(
               ctx.owner,
               ctx.identity,
               true,
               ctx.deployer,
               ctx.identity
             )
    end
  end
end
