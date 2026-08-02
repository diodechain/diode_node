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

    Shell.submit_tx(tx)
    |> case do
      tx_id when is_binary(tx_id) ->
        IO.inspect(DiodeClient.Transaction.hash(tx) |> Base16.encode())
        IO.inspect(tx_id)
        BnsMigrate.await_tx_ref(tx_id, tx)

      :already_known ->
        tx_id = DiodeClient.Transaction.hash(tx) |> Base16.encode()
        BnsMigrate.await_tx_ref(tx_id, tx)

      {:error, error} ->
        if out_of_gas_error?(error) do
          raise "Out of gas / insufficient funds, stopping: #{inspect(error)}"
        end

        Logger.error("Failed to submit transaction: #{inspect(error)}, retrying... in 10 seconds")
        Process.sleep(10_000)
        submit_tx(tx, retries - 1)
    end
  end

  def await_txs(pending) do
    pending
    |> Enum.reverse()
    |> Enum.with_index(1)
    |> Enum.each(fn {{tx_id, _tx} = ref, idx} ->
      IO.puts("Awaiting TX-#{idx} #{tx_id} ...")
      Shell.await_tx_id(ref)
    end)
  end

  def ensure_gas!(wallet) do
    balance = Shell.get_balance(Chains.Base, Wallet.address!(wallet))

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

  def identity_salt(owner), do: BnsMigrate.identity_salt(owner)
  def repair_salt(owner), do: BnsMigrate.repair_salt(owner)

  def identity_address(salt) when is_binary(salt) and byte_size(salt) == 32 do
    data = ABI.encode_call("Create2Address", ["bytes32"], [salt]) |> Base16.encode()

    RemoteChain.RPC.call!(Chains.Base, to: Base16.encode(@factory), data: data)
    |> Base16.decode()
    |> Hash.to_address()
  end

  def identity_deployed?(salt) when is_binary(salt) and byte_size(salt) == 32 do
    addr = identity_address(salt)
    {addr, has_code?(Chains.Base, addr)}
  end

  def has_code?(chain, address) do
    code = RemoteChain.RPC.get_code(chain, Base16.encode(address))
    Base16.decode(code) != ""
  end

  def null?(address), do: BnsMigrate.null_address?(address, @null)

  def resolve_owner(name) do
    case call_address_soft(Chains.Base, @bns, "ResolveOwner", ["string"], [name]) do
      {:ok, addr} ->
        addr

      {:error, error} ->
        IO.puts("ResolveOwner(#{inspect(name)}) reverted: #{inspect(error)}")
        @null
    end
  end

  def resolve_destination(name) do
    case call_address_soft(Chains.Base, @bns, "Resolve", ["string"], [name]) do
      {:ok, addr} ->
        addr

      {:error, error} ->
        IO.puts("Resolve(#{inspect(name)}) reverted: #{inspect(error)}")
        @null
    end
  end

  def diode_resolve_destination(name) do
    # Diode L1 BNS Resolve() eth_call is unreliable for historical names; read storage
    # the same way diode_client / the original dump does (slot 1 = names).
    name_hash = Hash.keccak_256(name)
    base = Hash.to_bytes32(1)
    dest_slot = Hash.keccak_256(name_hash <> base)

    RemoteChain.RPC.get_storage_at(
      Chains.Diode,
      Base16.encode(@diode_bns),
      Base16.encode(dest_slot, false)
    )
    |> Base16.decode()
    |> Hash.to_address()
  end

  def diode_resolve_owner(name) do
    name_hash = Hash.keccak_256(name)
    base = Hash.to_bytes32(1)

    owner_slot =
      Hash.keccak_256(name_hash <> base)
      |> :binary.decode_unsigned()
      |> Kernel.+(1)
      |> :binary.encode_unsigned()

    RemoteChain.RPC.get_storage_at(
      Chains.Diode,
      Base16.encode(@diode_bns),
      Base16.encode(owner_slot, false)
    )
    |> Base16.decode()
    |> Hash.to_address()
  end

  def owner_of(chain, identity) do
    call_address(chain, identity, "owner", [], [])
  end

  def members_of(chain, identity) do
    call_address_array(chain, identity, "Members")
  end

  def non_owner_members(chain, identity) do
    owner = owner_of(chain, identity)
    Enum.reject(members_of(chain, identity), &(&1 == owner))
  end

  def broken_identity?(base_identity, l1_identity) do
    BnsMigrate.broken_identity?(
      has_code?(Chains.Base, base_identity),
      has_code?(Chains.Diode, l1_identity),
      non_owner_members(Chains.Base, base_identity),
      non_owner_members(Chains.Diode, l1_identity)
    )
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
            IO.puts(
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

    case RemoteChain.RPC.call(chain, to: Base16.encode(to), data: data) do
      {:ok, ret} -> {:ok, ret |> Base16.decode() |> Hash.to_address()}
      {:error, error} -> {:error, error}
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

    case RemoteChain.RPC.call(chain, to: Base16.encode(to), data: data) do
      {:ok, ret} ->
        result = Base16.decode(ret)

        list =
          case ABI.decode_args(["address[]"], result) do
            [addrs] when is_list(addrs) -> Enum.reject(addrs, &null?/1)
            _ -> []
          end

        {:ok, list}

      {:error, error} ->
        {:error, error}
    end
  end

  defp members_of_soft(chain, identity) do
    case call_address_array_soft(chain, identity, "Members") do
      {:ok, list} ->
        list

      {:error, error} ->
        IO.puts("Members(#{Base16.encode(identity)}) reverted: #{inspect(error)}")
        []
    end
  end

  def submit(wallet, to, method, types, args, nonce) do
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

    {submit_tx(tx), nonce + 1}
  end

  def create_identity(wallet, salt, nonce) do
    IO.puts("TX: Create identity as deployer salt=#{Base16.encode(salt)} ...")

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
        IO.puts("TX: AddMember #{Base16.encode(member)} ...")
        {id, n2} = submit(wallet, identity, "AddMember", ["address"], [member], n)
        {n2, [id | acc]}
      end)

    {nonce, txs} =
      if plan.remove_deployer? do
        IO.puts("TX: RemoveMember deployer #{Base16.encode(deployer)} ...")
        {id, n2} = submit(wallet, identity, "RemoveMember", ["address"], [deployer], nonce)
        {n2, [id | txs]}
      else
        {nonce, txs}
      end

    {nonce, txs} =
      if plan.transfer? do
        IO.puts("TX: transferOwnership -> #{Base16.encode(final_owner)} ...")

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
          sync_members(wallet, identity, final_owner, fleet, deployer, n)

        true ->
          owner = owner_of(Chains.Base, identity)
          complete? = members_complete?(identity, fleet, deployer)

          cond do
            owner == deployer ->
              IO.puts("TX: Sync members on #{Base16.encode(identity)} ...")
              sync_members(wallet, identity, final_owner, fleet, deployer, nonce)

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
    IO.puts("TX: Register #{name} -> #{Base16.encode(identity)} (BNSAdmin) ...")
    {id_reg, n} = submit(wallet, @bns, "Register", ["string", "address"], [name, identity], nonce)

    IO.puts("TX: TransferOwner #{name} -> #{Base16.encode(final_owner)} ...")

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
    base_dest = resolve_destination(name)
    base_owner = resolve_owner(name)
    {fleet, l1_identity} = origin_fleet(name, owner)

    current_identity =
      BnsMigrate.select_current_identity(
        base_dest,
        not null?(base_dest) and has_code?(Chains.Base, base_dest),
        v1_identity,
        v1_deployed?
      )

    broken? =
      is_binary(current_identity) and is_binary(l1_identity) and
        broken_identity?(current_identity, l1_identity)

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

    IO.puts("\n=== DRY-RUN #{name} ===")
    IO.puts("action: #{inspect(action)}")
    IO.puts("owner: #{Base16.encode(owner)}")
    IO.puts("base_owner: #{fmt_addr(base_owner)}")
    IO.puts("base_dest: #{fmt_addr(base_dest)}")
    IO.puts("current_identity: #{fmt_addr(current_identity)}")
    IO.puts("l1_identity: #{fmt_addr(l1_identity)}")
    IO.puts("broken?: #{broken?} repaired?: #{repaired?}")
    IO.puts("v1: #{Base16.encode(v1_identity)} deployed?=#{v1_deployed?}")
    IO.puts("repair: #{Base16.encode(repair_identity)} deployed?=#{repair_deployed?}")
    IO.puts("fleet (#{length(fleet)}):")

    Enum.each(fleet, fn addr ->
      IO.puts("  #{Base16.encode(addr)}")
    end)

    case action do
      :repair ->
        print_identity_plan("repair", repair_identity, repair_deployed?, owner, fleet, deployer)
        print_bns_plan(name, repair_identity, owner, base_owner, base_dest)

      :create ->
        print_identity_plan("v1", v1_identity, false, owner, fleet, deployer)
        print_bns_plan(name, v1_identity, owner, base_owner, base_dest)

      :resume_v1 ->
        print_identity_plan("v1", v1_identity, true, owner, fleet, deployer)
        print_bns_plan(name, v1_identity, owner, base_owner, base_dest)

      :bns_v1 ->
        print_bns_plan(name, v1_identity, owner, base_owner, base_dest)

      nil ->
        IO.puts("No work.")
    end
  end

  defp print_identity_plan(label, identity, deployed?, owner, fleet, deployer) do
    current_members = if deployed?, do: members_of(Chains.Base, identity), else: []
    current_owner = if deployed?, do: owner_of(Chains.Base, identity), else: deployer
    plan = BnsMigrate.sync_member_plan(current_members, fleet, deployer, owner, current_owner)

    IO.puts("""
    Would #{if deployed?, do: "sync", else: "create+sync"} #{label} identity #{Base16.encode(identity)}:
      Create?=#{not deployed?}
      AddMember x#{length(plan.add)}
    #{Enum.map(plan.add, fn a -> "        - #{Base16.encode(a)}" end) |> Enum.join("\n")}
      RemoveMember(deployer)?=#{plan.remove_deployer?}
      transferOwnership(#{Base16.encode(owner)})?=#{plan.transfer?}
    """)
  end

  defp print_bns_plan(name, identity, owner, base_owner, base_dest) do
    if BnsMigrate.needs_bns_register?(base_owner, owner, base_dest, identity) do
      IO.puts("""
      Would update BNS:
        Register("#{name}", #{Base16.encode(identity)})
        TransferOwner("#{name}", #{Base16.encode(owner)})
      """)
    else
      IO.puts("BNS already points at #{Base16.encode(identity)} owned by #{Base16.encode(owner)}")
    end
  end

  defp fmt_addr(nil), do: "nil"
  defp fmt_addr(addr), do: if(null?(addr), do: "nil", else: Base16.encode(addr))
end

# curl -k -H "Content-Type: application/json" -X POST --data '{"jsonrpc":"2.0","method":"eth_getStorage","params":["0xaf60faa5cd840b724742f1af116168276112d6a6", "latest"],"id":73}' https://prenet.diode.io:8443 > bns_2026_08_01.json

{dry_run, only_names} =
  case BnsMigrate.parse_argv(System.argv()) do
    {:ok, %{dry_run: dry_run, names: names}} ->
      only =
        names
        |> Enum.map(&BnsMigrate.normalize_name/1)
        |> Enum.reject(&(&1 == ""))

      {dry_run, only}

    {:error, {:unknown_args, unknown}} ->
      IO.puts(:stderr, """
      Unknown argument(s): #{Enum.join(unknown, ", ")}

      Usage:
        elixir bns.exs [--dry-run] [name ...]
      """)

      System.halt(1)
  end

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
  IO.puts("Names not in dump (owner will be resolved on-chain): #{Enum.join(missing, ", ")}")
end

{names, invalid_names} = BnsMigrate.partition_valid_names(names)

Enum.each(invalid_names, fn name ->
  IO.puts(
    "SKIP #{name}: invalid Base BNS name (need 8-32 chars of [0-9a-z-], no leading/trailing '-')"
  )
end)

if only_names != [] do
  IO.puts("Filter: #{Enum.join(only_names, ", ")}")
end

if dry_run do
  IO.puts("Mode: dry-run (no transactions)")
end

IO.puts("Names: #{length(names)} (skipped invalid: #{length(invalid_names)})")
{:ok, _dets} = DetsPlus.open_file(:base_cache)

wallet = Wallet.from_privkey(Base16.decode(String.trim(File.read!("diode_glmr.key"))))
deployer = Wallet.address!(wallet)

if deployer != Helper.bns_admin() do
  raise "diode_glmr.key must be BNSAdmin #{Base16.encode(Helper.bns_admin())}, got #{Base16.encode(deployer)}"
end

work =
  for name <- names do
    name_hash = Hash.keccak_256(name)
    base = Hash.to_bytes32(1)

    owner_slot =
      Hash.keccak_256(name_hash <> base)
      |> :binary.decode_unsigned()
      |> Kernel.+(1)
      |> :binary.encode_unsigned()

    owner =
      case Map.get(storage, owner_slot) do
        nil -> Helper.resolve_name_owner(name)
        owner_raw -> Hash.to_address(owner_raw)
      end

    if owner == nil or Helper.null?(owner) do
      IO.puts("SKIP #{name}: could not resolve name owner")
      nil
    else
      v1_salt = Helper.identity_salt(owner)
      repair_salt = Helper.repair_salt(owner)

      {v1_identity, v1_deployed?} =
        case BnsMigrate.parse_identity_cache(DetsPlus.lookup(:base_cache, owner_slot)) do
          {:ok, identity, deployed?} ->
            {identity, deployed?}

          status when status in [:stale, :miss] ->
            if status == :stale do
              IO.puts("Cache status for #{name} is stale atom; re-resolving identity on-chain")
            else
              IO.inspect({name, Base16.encode(owner)})
            end

            {identity, deployed?} = Helper.identity_deployed?(v1_salt)
            base_owner = Helper.resolve_owner(name)
            base_dest = Helper.resolve_destination(name)

            DetsPlus.insert(:base_cache, [
              {owner_slot, {identity, deployed?, base_owner, base_dest}}
            ])

            {identity, deployed?}

          {:error, other} ->
            raise "Unexpected base_cache entry for #{name}: #{inspect(other)}"
        end

      {repair_identity, repair_deployed?} = Helper.identity_deployed?(repair_salt)

      item =
        Helper.classify_work_item(
          name,
          owner,
          deployer,
          v1_identity,
          v1_deployed?,
          repair_identity,
          repair_deployed?
        )

      if item.action do
        if item.action == :repair do
          IO.puts(
            "REPAIR #{name}: broken #{Base16.encode(item.current_identity)} (owner-only on Base, fleet on L1) -> #{Base16.encode(repair_identity)}"
          )
        end

        {item.action, name, owner, owner_slot, item.fleet, v1_salt, v1_identity, repair_salt,
         repair_identity, item}
      end
    end
  end
  |> Enum.reject(&is_nil/1)

{repairs, _other} =
  Enum.split_with(work, fn {action, _, _, _, _, _, _, _, _, _} -> action == :repair end)

IO.puts("Work: #{length(work)} (repairs=#{length(repairs)})")
DetsPlus.sync(:base_cache)

if dry_run do
  Enum.each(work, fn {_action, _name, _owner, _slot, _fleet, _v1_salt, _v1_id, _r_salt, _r_id,
                      item} ->
    Helper.print_dry_run(item, deployer)
  end)

  IO.puts("\nDone (dry-run). #{length(work)} item(s).")
else
  work =
    Enum.shuffle(work)
    |> Enum.chunk_every(1)

  for chunk <- work do
    balance = Helper.ensure_gas!(wallet)
    IO.puts("Wallet: #{Base16.encode(deployer)} Balance: #{balance}")

    Enum.each(
      chunk,
      fn {action, name, owner, slot, fleet, v1_salt, v1_identity, repair_salt, _repair_identity,
          _item} ->
        Process.sleep(100)
        DetsPlus.delete(:base_cache, slot)
        DetsPlus.sync(:base_cache)

        nonce =
          RemoteChain.RPC.get_transaction_count(Chains.Base, Base16.encode(deployer))
          |> Base16.decode_int()

        IO.puts(
          "Prepare #{name} action=#{action} owner=#{Base16.encode(owner)} fleet=#{length(fleet)} ..."
        )

        case action do
          :repair ->
            {identity, _n} =
              Helper.ensure_identity(wallet, repair_salt, owner, fleet, deployer, nonce)

            base_dest = Helper.resolve_destination(name)
            base_owner = Helper.resolve_owner(name)

            if BnsMigrate.needs_bns_register?(base_owner, owner, base_dest, identity) do
              nonce =
                RemoteChain.RPC.get_transaction_count(Chains.Base, Base16.encode(deployer))
                |> Base16.decode_int()

              Helper.register_bns(wallet, name, identity, owner, nonce)
            end

          :create ->
            {identity, _n} =
              Helper.ensure_identity(wallet, v1_salt, owner, fleet, deployer, nonce)

            base_dest = Helper.resolve_destination(name)
            base_owner = Helper.resolve_owner(name)

            if BnsMigrate.needs_bns_register?(base_owner, owner, base_dest, identity) do
              nonce =
                RemoteChain.RPC.get_transaction_count(Chains.Base, Base16.encode(deployer))
                |> Base16.decode_int()

              Helper.register_bns(wallet, name, identity, owner, nonce)
            end

          :resume_v1 ->
            {_identity, _n} =
              Helper.ensure_identity(wallet, v1_salt, owner, fleet, deployer, nonce)

            base_dest = Helper.resolve_destination(name)
            base_owner = Helper.resolve_owner(name)

            if BnsMigrate.needs_bns_register?(base_owner, owner, base_dest, v1_identity) do
              nonce =
                RemoteChain.RPC.get_transaction_count(Chains.Base, Base16.encode(deployer))
                |> Base16.decode_int()

              Helper.register_bns(wallet, name, v1_identity, owner, nonce)
            end

          :bns_v1 ->
            Helper.register_bns(wallet, name, v1_identity, owner, nonce)
        end
      end
    )
  end
end
