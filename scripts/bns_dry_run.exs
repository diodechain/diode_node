# Dry-run repair detection for a single name (no transactions).
# Usage (from diode-drive or any OTP-26 elixir):
#   elixir /path/to/diode_node/scripts/bns_dry_run.exs knusperhaus

Mix.install(
  [
    {:diode, path: __DIR__ <> "/../"},
    {:dets_plus, "~> 2.1"}
  ],
  config: [diode: [no_start: true]]
)

alias DiodeClient.{Secp256k1, Base16, Hash, Wallet}

name = Enum.at(System.argv(), 0) || "knusperhaus"

{:ok, _pid} =
  Supervisor.start_link([{RemoteChain.Sup, Chains.Base}], strategy: :rest_for_one)

{:ok, _pid} = Supervisor.start_link([{RemoteChain.Sup, Chains.Diode}], strategy: :rest_for_one)
:persistent_term.put(:identity, Secp256k1.generate())
Logger.configure(level: :warning)

# Extract Helper from bns.exs (lines between defmodule Helper and its terminating end)
bns_lines = File.read!(Path.join(__DIR__, "bns.exs")) |> String.split("\n")
start_idx = Enum.find_index(bns_lines, &(&1 == "defmodule Helper do"))

end_idx =
  Enum.find(start_idx..(length(bns_lines) - 1), fn i ->
    Enum.at(bns_lines, i) == "end" and
      Enum.at(bns_lines, i + 1) in [nil, ""] and
      String.starts_with?(Enum.at(bns_lines, i + 2) || "", "#")
  end) ||
    raise "Could not find Helper module end in bns.exs"

helper_src = Enum.slice(bns_lines, start_idx..end_idx) |> Enum.join("\n")
Code.eval_string(helper_src)

wallet = Wallet.from_privkey(Base16.decode(String.trim(File.read!(Path.join(__DIR__, "diode_glmr.key")))))
deployer = Wallet.address!(wallet)

IO.puts("=== BNS repair dry-run: #{name} ===")
IO.puts("deployer/admin: #{Base16.encode(deployer)}")
IO.puts("BNSAdmin expected: #{Base16.encode(Helper.bns_admin())}")
IO.puts("admin match?: #{deployer == Helper.bns_admin()}")

base_owner = Helper.resolve_owner(name)
base_dest = Helper.resolve_destination(name)
l1_dest = Helper.diode_resolve_destination(name)

IO.puts("\n--- BNS ---")
IO.puts("Base owner: #{if(Helper.null?(base_owner), do: "nil", else: Base16.encode(base_owner))}")
IO.puts("Base dest:  #{if(Helper.null?(base_dest), do: "nil", else: Base16.encode(base_dest))}")
IO.puts("L1 dest:    #{if(Helper.null?(l1_dest), do: "nil", else: Base16.encode(l1_dest))}")

owner =
  cond do
    not Helper.null?(base_owner) -> base_owner
    not Helper.null?(l1_dest) -> Helper.owner_of(Chains.Diode, l1_dest)
    true -> raise "Cannot determine BNS/name owner for #{name}"
  end

{fleet, l1_identity} = Helper.origin_fleet(name, owner)
v1_salt = Helper.identity_salt(owner)
repair_salt = Helper.repair_salt(owner)
{v1_identity, v1_deployed?} = Helper.identity_deployed?(v1_salt)
{repair_identity, repair_deployed?} = Helper.identity_deployed?(repair_salt)

IO.puts("\n--- Owner / salts ---")
IO.puts("name owner (final): #{Base16.encode(owner)}")
IO.puts("v1 salt:     #{Base16.encode(v1_salt)}")
IO.puts("v1 identity: #{Base16.encode(v1_identity)} deployed?=#{v1_deployed?}")
IO.puts("repair salt: #{Base16.encode(repair_salt)}")
IO.puts("repair id:   #{Base16.encode(repair_identity)} deployed?=#{repair_deployed?}")

IO.puts("\n--- Origin fleet (L1) ---")
IO.puts("l1 identity: #{if(l1_identity, do: Base16.encode(l1_identity), else: "nil")}")
IO.puts("fleet (#{length(fleet)}):")

l1_id_owner = if l1_identity, do: Helper.owner_of(Chains.Diode, l1_identity)

Enum.each(fleet, fn addr ->
  tag =
    cond do
      addr == owner -> "bns-owner"
      addr == l1_id_owner -> "l1-id-owner"
      true -> "member"
    end

  IO.puts("  #{Base16.encode(addr)}  (#{tag})")
end)

if is_binary(l1_identity) do
  l1_members = Helper.members_of(Chains.Diode, l1_identity)
  l1_non = Helper.non_owner_members(Chains.Diode, l1_identity)

  IO.puts("\n--- L1 identity detail ---")
  IO.puts("owner: #{Base16.encode(l1_id_owner)}")
  IO.puts("Members() count: #{length(l1_members)}")
  IO.puts("non-owner members: #{length(l1_non)}")
  Enum.each(l1_non, fn a -> IO.puts("  #{Base16.encode(a)}") end)
end

current_identity =
  cond do
    not Helper.null?(base_dest) and Helper.has_code?(Chains.Base, base_dest) -> base_dest
    v1_deployed? -> v1_identity
    true -> nil
  end

IO.puts("\n--- Current Base identity ---")
IO.puts("current: #{if(current_identity, do: Base16.encode(current_identity), else: "nil")}")

broken? =
  is_binary(current_identity) and is_binary(l1_identity) and
    Helper.broken_identity?(current_identity, l1_identity)

if is_binary(current_identity) do
  b_owner = Helper.owner_of(Chains.Base, current_identity)
  b_members = Helper.members_of(Chains.Base, current_identity)
  b_non = Helper.non_owner_members(Chains.Base, current_identity)

  IO.puts("owner: #{Base16.encode(b_owner)}")
  IO.puts("Members(): #{Enum.map(b_members, &Base16.encode/1) |> inspect()}")
  IO.puts("non-owner members: #{length(b_non)}")
  IO.puts("broken_identity?: #{broken?}")
end

repaired? =
  repair_deployed? and base_dest == repair_identity and
    Helper.members_complete?(repair_identity, fleet, deployer)

action =
  cond do
    repaired? -> nil
    broken? -> :repair
    not v1_deployed? -> :create
    v1_deployed? and Helper.owner_of(Chains.Base, v1_identity) == deployer -> :resume_v1
    Helper.null?(base_owner) or base_owner != owner or base_dest != v1_identity -> :bns_v1
    true -> nil
  end

IO.puts("\n=== RESULT ===")
IO.puts("action: #{inspect(action)}")
IO.puts("already repaired?: #{repaired?}")

if action == :repair do
  missing_members =
    if repair_deployed? do
      current = MapSet.new(Helper.members_of(Chains.Base, repair_identity))

      fleet
      |> Enum.reject(&(&1 == deployer))
      |> Enum.reject(&MapSet.member?(current, &1))
    else
      Enum.reject(fleet, &(&1 == deployer))
    end

  IO.puts("""

  Would execute (DRY RUN — no txs sent):
  1. Create(deployer, repair_salt, DriveMember) -> #{Base16.encode(repair_identity)}
     already_deployed=#{repair_deployed?}
  2. AddMember x#{length(missing_members)}:
  #{Enum.map(missing_members, fn a -> "     - #{Base16.encode(a)}" end) |> Enum.join("\n")}
  3. RemoveMember(deployer) if present and not in fleet
  4. transferOwnership(#{Base16.encode(owner)})
  5. BNSAdmin Register("#{name}", #{Base16.encode(repair_identity)})
  6. TransferOwner("#{name}", #{Base16.encode(owner)})
  """)

  if repair_deployed? do
    r_owner = Helper.owner_of(Chains.Base, repair_identity)
    r_members = Helper.members_of(Chains.Base, repair_identity)
    complete? = Helper.members_complete?(repair_identity, fleet, deployer)

    IO.puts("Repair identity already exists:")
    IO.puts("  owner: #{Base16.encode(r_owner)}")
    IO.puts("  Members(): #{Enum.map(r_members, &Base16.encode/1) |> inspect()}")
    IO.puts("  members_complete?: #{complete?}")
    IO.puts("  BNS already points here?: #{base_dest == repair_identity}")
  end
end

IO.puts("Done (dry-run).")
