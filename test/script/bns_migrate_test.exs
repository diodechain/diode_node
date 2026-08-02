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
    member = addr(5)
    zero = BnsMigrate.zero_address()

    {:ok,
     deployer: deployer,
     owner: owner,
     identity: identity,
     foreign: foreign,
     member: member,
     zero: zero}
  end

  describe "parse_argv/1" do
    test "empty argv is live run with no name filter" do
      assert {:ok, %{dry_run: false, names: []}} = BnsMigrate.parse_argv([])
    end

    test "accepts --dry-run and name filters" do
      assert {:ok, %{dry_run: true, names: ["knusperhaus", "foo.base"]}} =
               BnsMigrate.parse_argv(["--dry-run", "knusperhaus", "foo.base"])
    end

    test "accepts names before --dry-run" do
      assert {:ok, %{dry_run: true, names: ["a"]}} = BnsMigrate.parse_argv(["a", "--dry-run"])
    end

    test "rejects unknown flags" do
      assert {:error, {:unknown_args, ["--force", "-x"]}} =
               BnsMigrate.parse_argv(["--force", "name", "-x", "--dry-run"])
    end

    test "rejects single-dash unknowns" do
      assert {:error, {:unknown_args, ["-h"]}} = BnsMigrate.parse_argv(["-h"])
    end
  end

  describe "normalize_name/1" do
    test "trims, lowercases, and strips known suffixes" do
      assert BnsMigrate.normalize_name("  KnusperHaus.diode ") == "knusperhaus"
      assert BnsMigrate.normalize_name("Foo.BASE") == "foo"
      assert BnsMigrate.normalize_name("bar.glmr") == "bar"
      assert BnsMigrate.normalize_name("baz.sapphire") == "baz"
    end
  end

  describe "apply_name_filter/2" do
    test "no filter returns all names" do
      assert {["a", "b"], []} = BnsMigrate.apply_name_filter(["a", "b"], [])
    end

    test "keeps dump names and appends missing for on-chain resolve" do
      assert {["a", "missing"], ["missing"]} =
               BnsMigrate.apply_name_filter(["a", "b"], ["a", "missing"])
    end
  end

  describe "sufficient_gas?/1" do
    test "rejects balances below one finney" do
      refute BnsMigrate.sufficient_gas?(BnsMigrate.min_gas_wei() - 1)
      assert BnsMigrate.sufficient_gas?(BnsMigrate.min_gas_wei())
      assert BnsMigrate.sufficient_gas?(BnsMigrate.min_gas_wei() + 1)
    end

    test "min_gas_wei matches Shell.finney(1)" do
      assert BnsMigrate.min_gas_wei() == Shell.finney(1)
    end
  end

  describe "await_tx_ref/2" do
    test "builds the {tx_id, tx} tuple Shell.await_tx_id/1 requires" do
      tx_id = "0xbde62b36a0b92c3e826ddc83fc1a84acdb660d4ca45c1eb8354cd5014b17aa61"
      tx = :fake_tx_for_shape_check

      assert {^tx_id, ^tx} = BnsMigrate.await_tx_ref(tx_id, tx)
    end

    test "bare tx_id string does not match Shell.await_tx_id/1 (production regression)" do
      # Bug: scripts/bns.exs called Shell.await_tx_id(tx_id) after submit returned
      # only the hash. Default n=0 makes this await_tx_id(binary, 0), which misses
      # the only clause: await_tx_id({tx_id, tx}, n).
      tx_id = "0xbde62b36a0b92c3e826ddc83fc1a84acdb660d4ca45c1eb8354cd5014b17aa61"

      assert_raise FunctionClauseError, fn ->
        apply(Shell, :await_tx_id, [tx_id])
      end
    end
  end

  describe "parse_identity_cache/1" do
    test "reads full and truncated identity tuples", ctx do
      slot = <<1, 2, 3>>
      identity = ctx.identity

      assert {:ok, ^identity, true} =
               BnsMigrate.parse_identity_cache([
                 {slot, {identity, true, ctx.owner, identity}}
               ])

      assert {:ok, ^identity, false} =
               BnsMigrate.parse_identity_cache([{slot, {identity, false}}])
    end

    test "treats migrator atom statuses as stale (production regression)" do
      slot = Hash.keccak_256("owner-slot")

      for status <- [:done, :foreign_owner, :owner_controlled, :invalid] do
        assert :stale = BnsMigrate.parse_identity_cache([{slot, status}])
      end

      # Exact shape that crashed repair when knusperhaus was cached as :done
      assert :stale =
               BnsMigrate.parse_identity_cache([
                 {<<96, 160, 174, 160, 225, 3, 23, 75, 99, 47, 206, 92, 2, 249, 65, 190, 70, 84,
                    68, 197, 135, 145, 174, 13, 49, 229, 135, 219, 142, 129, 186, 225>>, :done}
               ])
    end

    test "empty lookup is a miss" do
      assert :miss = BnsMigrate.parse_identity_cache([])
    end

    test "unexpected shapes are errors" do
      assert {:error, [{"x", "bad"}]} = BnsMigrate.parse_identity_cache([{"x", "bad"}])
    end
  end

  describe "valid_bns_name?/1" do
    test "accepts lowercase names matching Base BNS validate()" do
      assert BnsMigrate.valid_bns_name?("knusperhaus")
      assert BnsMigrate.valid_bns_name?("private-ten")
      assert BnsMigrate.valid_bns_name?("abcdefgh")
    end

    test "rejects uppercase that reverts ResolveOwner (production regression)" do
      refute BnsMigrate.valid_bns_name?("Private-Ten")
    end

    test "rejects length and charset violations" do
      refute BnsMigrate.valid_bns_name?("short")
      refute BnsMigrate.valid_bns_name?("under_score_name")
      refute BnsMigrate.valid_bns_name?("-leadingok")
      refute BnsMigrate.valid_bns_name?("trailing-")
      refute BnsMigrate.valid_bns_name?(String.duplicate("a", 33))
    end

    test "partition_valid_names/1 separates invalid dump names" do
      assert {["knusperhaus"], ["Private-Ten"]} =
               BnsMigrate.partition_valid_names(["Private-Ten", "knusperhaus"])
    end
  end

  describe "identity and repair salts" do
    test "are deterministic and distinct", ctx do
      v1 = BnsMigrate.identity_salt(ctx.owner)
      repair = BnsMigrate.repair_salt(ctx.owner)

      assert byte_size(v1) == 32
      assert byte_size(repair) == 32
      assert v1 != repair
      assert v1 == BnsMigrate.identity_salt(ctx.owner)
    end
  end

  describe "select_current_identity/4" do
    test "prefers live BNS destination with code", ctx do
      assert BnsMigrate.select_current_identity(ctx.foreign, true, ctx.identity, true) ==
               ctx.foreign
    end

    test "falls back to v1 when dest missing or no code", ctx do
      assert BnsMigrate.select_current_identity(ctx.zero, false, ctx.identity, true) ==
               ctx.identity

      assert BnsMigrate.select_current_identity(ctx.foreign, false, ctx.identity, true) ==
               ctx.identity
    end

    test "nil when nothing usable", ctx do
      assert BnsMigrate.select_current_identity(ctx.zero, false, ctx.identity, false) == nil
    end
  end

  describe "build_origin_fleet/4" do
    test "falls back to BNS owner when L1 owner unavailable", ctx do
      assert {fleet, nil} =
               BnsMigrate.build_origin_fleet(ctx.owner, nil, [ctx.member], ctx.identity)

      assert fleet == [ctx.owner]
    end

    test "uniques owner, bns owner, and members; drops zero", ctx do
      {fleet, dest} =
        BnsMigrate.build_origin_fleet(
          ctx.owner,
          ctx.foreign,
          [ctx.member, ctx.zero, ctx.owner],
          ctx.identity
        )

      assert dest == ctx.identity
      assert fleet == [ctx.foreign, ctx.owner, ctx.member]
    end
  end

  describe "broken_identity?/4" do
    test "true when Base has no fleet but L1 does" do
      assert BnsMigrate.broken_identity?(true, true, [], [addr(9)])
    end

    test "false when Base already has non-owner members" do
      refute BnsMigrate.broken_identity?(true, true, [addr(9)], [addr(9)])
    end

    test "false when L1 has no fleet either" do
      refute BnsMigrate.broken_identity?(true, true, [], [])
    end

    test "false without code on either side" do
      refute BnsMigrate.broken_identity?(false, true, [], [addr(9)])
      refute BnsMigrate.broken_identity?(true, false, [], [addr(9)])
    end
  end

  describe "members_complete?/3" do
    test "complete when fleet subset and deployer not leftover", ctx do
      assert BnsMigrate.members_complete?(
               [ctx.owner, ctx.member],
               [ctx.owner, ctx.member],
               ctx.deployer
             )
    end

    test "incomplete when fleet member missing", ctx do
      refute BnsMigrate.members_complete?([ctx.owner], [ctx.owner, ctx.member], ctx.deployer)
    end

    test "incomplete when deployer still a member but not in fleet", ctx do
      refute BnsMigrate.members_complete?(
               [ctx.owner, ctx.deployer],
               [ctx.owner],
               ctx.deployer
             )
    end

    test "allows deployer member when deployer is in fleet", ctx do
      assert BnsMigrate.members_complete?(
               [ctx.owner, ctx.deployer],
               [ctx.owner, ctx.deployer],
               ctx.deployer
             )
    end
  end

  describe "classify_repair_action/1" do
    test "nil when already repaired" do
      assert BnsMigrate.classify_repair_action(%{
               repaired?: true,
               broken?: true,
               v1_deployed?: false,
               v1_owned_by_deployer?: false,
               bns_needs_v1?: true
             }) == nil
    end

    test "repair wins over create when broken" do
      assert BnsMigrate.classify_repair_action(%{
               repaired?: false,
               broken?: true,
               v1_deployed?: false,
               v1_owned_by_deployer?: false,
               bns_needs_v1?: false
             }) == :repair
    end

    test "create when not deployed" do
      assert BnsMigrate.classify_repair_action(%{
               repaired?: false,
               broken?: false,
               v1_deployed?: false,
               v1_owned_by_deployer?: false,
               bns_needs_v1?: true
             }) == :create
    end

    test "resume_v1 when deployer still owns v1" do
      assert BnsMigrate.classify_repair_action(%{
               repaired?: false,
               broken?: false,
               v1_deployed?: true,
               v1_owned_by_deployer?: true,
               bns_needs_v1?: true
             }) == :resume_v1
    end

    test "bns_v1 when only BNS update needed" do
      assert BnsMigrate.classify_repair_action(%{
               repaired?: false,
               broken?: false,
               v1_deployed?: true,
               v1_owned_by_deployer?: false,
               bns_needs_v1?: true
             }) == :bns_v1
    end

    test "nil when nothing to do" do
      assert BnsMigrate.classify_repair_action(%{
               repaired?: false,
               broken?: false,
               v1_deployed?: true,
               v1_owned_by_deployer?: false,
               bns_needs_v1?: false
             }) == nil
    end
  end

  describe "repaired?/4 and bns_needs_v1?/6" do
    test "repaired when dest points at complete repair identity", ctx do
      assert BnsMigrate.repaired?(true, ctx.identity, ctx.identity, true)
      refute BnsMigrate.repaired?(true, ctx.foreign, ctx.identity, true)
      refute BnsMigrate.repaired?(false, ctx.identity, ctx.identity, true)
    end

    test "bns_needs_v1 when owner or dest mismatch", ctx do
      assert BnsMigrate.bns_needs_v1?(false, false, ctx.zero, ctx.owner, ctx.zero, ctx.identity)

      assert BnsMigrate.bns_needs_v1?(
               false,
               false,
               ctx.owner,
               ctx.owner,
               ctx.foreign,
               ctx.identity
             )

      refute BnsMigrate.bns_needs_v1?(true, false, ctx.zero, ctx.owner, ctx.zero, ctx.identity)
      refute BnsMigrate.bns_needs_v1?(false, true, ctx.zero, ctx.owner, ctx.zero, ctx.identity)

      refute BnsMigrate.bns_needs_v1?(
               false,
               false,
               ctx.owner,
               ctx.owner,
               ctx.identity,
               ctx.identity
             )
    end
  end

  describe "needs_bns_register?/4" do
    test "true until owner and dest match identity", ctx do
      assert BnsMigrate.needs_bns_register?(ctx.zero, ctx.owner, ctx.zero, ctx.identity)
      assert BnsMigrate.needs_bns_register?(ctx.deployer, ctx.owner, ctx.identity, ctx.identity)
      refute BnsMigrate.needs_bns_register?(ctx.owner, ctx.owner, ctx.identity, ctx.identity)
    end
  end

  describe "sync_member_plan/5" do
    test "plans adds, deployer removal, and ownership transfer", ctx do
      plan =
        BnsMigrate.sync_member_plan(
          [ctx.deployer],
          [ctx.owner, ctx.member],
          ctx.deployer,
          ctx.owner,
          ctx.deployer
        )

      assert Enum.sort(plan.add) == Enum.sort([ctx.owner, ctx.member])
      assert plan.remove_deployer?
      assert plan.transfer?
    end

    test "skips members already present and keeps deployer when in fleet", ctx do
      plan =
        BnsMigrate.sync_member_plan(
          [ctx.deployer, ctx.owner],
          [ctx.deployer, ctx.owner, ctx.member],
          ctx.deployer,
          ctx.owner,
          ctx.deployer
        )

      assert plan.add == [ctx.member]
      refute plan.remove_deployer?
      assert plan.transfer?
    end

    test "no transfer when already owned by final owner", ctx do
      plan =
        BnsMigrate.sync_member_plan(
          [ctx.owner, ctx.member],
          [ctx.owner, ctx.member],
          ctx.deployer,
          ctx.owner,
          ctx.owner
        )

      assert plan.add == []
      refute plan.remove_deployer?
      refute plan.transfer?
    end
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
