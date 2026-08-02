Mix.install(
  [
    {:diode, path: __DIR__ <> "/../"},
    {:dets_plus, "~> 2.1"}
  ],
  config: [diode: [no_start: true]]
)

alias DiodeClient.{Secp256k1, Base16, Hash, Wallet}

{:ok, _pid} =
  Supervisor.start_link([{RemoteChain.Sup, Chains.Base}], strategy: :rest_for_one)

{:ok, _pid} = Supervisor.start_link([{RemoteChain.Sup, Chains.Diode}], strategy: :rest_for_one)
:persistent_term.put(:identity, Secp256k1.generate())
Logger.configure(level: :warning)

defmodule Helper do
  require Logger
  alias DiodeClient.{ABI, Base16, Hash, Wallet}

  # Base Collab contracts (DiodeClient.Contracts.Factory.contracts(Shell.Base))
  @factory Base16.decode("0x1A36092D88FB73692EE7C502978D634C4AFCC486")
  # BNS proxy — implementation is BNSAdmin.sol v400 (admin can re-Register owned names)
  @bns Base16.decode("0x87C1D1304944A9EA16AF18CB777E3CEE0D3DACEA")
  @drive_member Base16.decode("0x3D565EC28595C1A0710ABCBD8C0F979D31E38704")
  @diode_bns Base16.decode("0xAF60FAA5CD840B724742F1AF116168276112D6A6")
  @null <<0::160>>
  # BNSAdmin.isAdmin/1 — must match diode_glmr.key
  @bns_admin Base16.decode("0x7102533B13b950c964efd346Ee15041E3e55413f")

  def factory, do: @factory
  def bns, do: @bns
  def drive_member, do: @drive_member
  def null, do: @null
  def bns_admin, do: @bns_admin

  def submit_tx(tx, retries \\ 30) do
    if retries == 0 do
      raise "Failed to submit transaction after #{retries} retries"
    end

    Shell.submit_tx(tx)
    |> case do
      tx_id when is_binary(tx_id) ->
        IO.inspect(DiodeClient.Transaction.hash(tx) |> Base16.encode())
        IO.inspect(tx_id)
        tx_id

      :already_known ->
        DiodeClient.Transaction.hash(tx) |> Base16.encode()

      {:error, error} ->
        if out_of_gas_error?(error) do
          raise "Out of gas / insufficient funds, stopping: #{inspect(error)}"
        end

        Logger.error("Failed to submit transaction: #{inspect(error)}, retrying... in 10 seconds")
        Process.sleep(10_000)
        submit_tx(tx, retries - 1)
    end
  end

  def await_txs(txs) do
    txs
    |> Enum.reverse()
    |> Enum.with_index(1)
    |> Enum.each(fn {tx_id, idx} ->
      IO.puts("Awaiting TX-#{idx} ...")
      Shell.await_tx_id(tx_id)
    end)
  end

  def ensure_gas!(wallet) do
    balance = Shell.get_balance(Chains.Base, Wallet.address!(wallet))

    if balance < Shell.ether(0.001) do
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

  # Original CREATE2 salt (first seeding pass).
  def identity_salt(owner), do: Hash.keccak_256(owner)

  # Repair salt — new identity when the original was created without fleet members.
  def repair_salt(owner), do: Hash.keccak_256("bns-repair-v1" <> owner)

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

  def null?(address), do: address == nil or address == @null

  def resolve_owner(name) do
    call_address(Chains.Base, @bns, "ResolveOwner", ["string"], [name])
  end

  def resolve_destination(name) do
    call_address(Chains.Base, @bns, "Resolve", ["string"], [name])
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

  @doc """
  Broken = Base identity has no non-owner members, but the Diode L1 counterpart
  has at least one non-owner member (fleet was never copied).
  """
  def broken_identity?(base_identity, l1_identity) do
    has_code?(Chains.Base, base_identity) and has_code?(Chains.Diode, l1_identity) and
      non_owner_members(Chains.Base, base_identity) == [] and
      non_owner_members(Chains.Diode, l1_identity) != []
  end

  @doc """
  Fleet devices to seed onto the Base identity, taken from the Diode L1 origin
  identity (owner + Members). Falls back to the BNS name owner when the Diode
  identity is missing.
  """
  def origin_fleet(name, bns_owner) do
    dest = diode_resolve_destination(name)

    cond do
      null?(dest) or not has_code?(Chains.Diode, dest) ->
        {[bns_owner], nil}

      true ->
        id_owner = owner_of(Chains.Diode, dest)
        members = members_of(Chains.Diode, dest)

        fleet =
          [id_owner, bns_owner | members]
          |> Enum.reject(&null?/1)
          |> Enum.uniq()

        {fleet, dest}
    end
  end

  def members_complete?(identity, fleet, deployer) do
    actual = MapSet.new(members_of(Chains.Base, identity))
    expected = MapSet.new(fleet)

    MapSet.subset?(expected, actual) and
      (deployer in fleet or not MapSet.member?(actual, deployer))
  end

  def call_address(chain, to, method, types, args) do
    data = ABI.encode_call(method, types, args) |> Base16.encode()

    RemoteChain.RPC.call!(chain, to: Base16.encode(to), data: data)
    |> Base16.decode()
    |> Hash.to_address()
  end

  def call_address_array(chain, to, method) do
    data = ABI.encode_call(method, [], []) |> Base16.encode()

    result =
      RemoteChain.RPC.call!(chain, to: Base16.encode(to), data: data)
      |> Base16.decode()

    case ABI.decode_args(["address[]"], result) do
      [list] when is_list(list) -> Enum.reject(list, &null?/1)
      _ -> []
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
    current = MapSet.new(members_of(Chains.Base, identity))

    to_add =
      fleet
      |> Enum.reject(&null?/1)
      |> Enum.reject(&(&1 == deployer))
      |> Enum.reject(&MapSet.member?(current, &1))
      |> Enum.uniq()

    {nonce, txs} =
      Enum.reduce(to_add, {nonce, []}, fn member, {n, acc} ->
        IO.puts("TX: AddMember #{Base16.encode(member)} ...")
        {id, n2} = submit(wallet, identity, "AddMember", ["address"], [member], n)
        {n2, [id | acc]}
      end)

    # Base DriveMember init adds the create-owner to Members(); drop seeder before
    # transfer unless the deployer is itself part of the origin fleet.
    {nonce, txs} =
      if deployer != final_owner and MapSet.member?(current, deployer) and
           deployer not in fleet do
        IO.puts("TX: RemoveMember deployer #{Base16.encode(deployer)} ...")
        {id, n2} = submit(wallet, identity, "RemoveMember", ["address"], [deployer], nonce)
        {n2, [id | txs]}
      else
        {nonce, txs}
      end

    {nonce, txs} =
      if owner_of(Chains.Base, identity) == deployer and deployer != final_owner do
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
end

# curl -k -H "Content-Type: application/json" -X POST --data '{"jsonrpc":"2.0","method":"eth_getStorage","params":["0xaf60faa5cd840b724742f1af116168276112d6a6", "latest"],"id":73}' https://prenet.diode.io:8443 > bns_2026_03_13.json

storage =
  File.read!("bns_2026_03_13.json")
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

IO.puts("Names: #{length(names)}")
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

    case Map.get(storage, owner_slot) do
      nil ->
        nil

      owner_raw ->
        owner = Hash.to_address(owner_raw)
        v1_salt = Helper.identity_salt(owner)
        repair_salt = Helper.repair_salt(owner)

        {v1_identity, v1_deployed?} =
          case DetsPlus.lookup(:base_cache, owner_slot) do
            [{^owner_slot, {identity, deployed?, _base_owner, _base_dest}}] ->
              {identity, deployed?}

            [{^owner_slot, cached}] when is_tuple(cached) and tuple_size(cached) >= 2 ->
              {elem(cached, 0), elem(cached, 1)}

            [] ->
              IO.inspect({name, Base16.encode(owner)})
              {identity, deployed?} = Helper.identity_deployed?(v1_salt)
              base_owner = Helper.resolve_owner(name)
              base_dest = Helper.resolve_destination(name)
              DetsPlus.insert(:base_cache, [{owner_slot, {identity, deployed?, base_owner, base_dest}}])
              {identity, deployed?}
          end

        base_dest = Helper.resolve_destination(name)
        base_owner = Helper.resolve_owner(name)
        {fleet, l1_identity} = Helper.origin_fleet(name, owner)
        {repair_identity, repair_deployed?} = Helper.identity_deployed?(repair_salt)

        # Prefer the live BNS destination when present; else the v1 CREATE2 address.
        current_identity =
          cond do
            not Helper.null?(base_dest) and Helper.has_code?(Chains.Base, base_dest) ->
              base_dest

            v1_deployed? ->
              v1_identity

            true ->
              nil
          end

        broken? =
          is_binary(current_identity) and is_binary(l1_identity) and
            Helper.broken_identity?(current_identity, l1_identity)

        # Already repaired: BNS points at repair identity with complete membership.
        repaired? =
          repair_deployed? and base_dest == repair_identity and
            Helper.members_complete?(repair_identity, fleet, deployer)

        bns_needs_v1? =
          not broken? and not repaired? and
            (Helper.null?(base_owner) or base_owner != owner or base_dest != v1_identity)

        action =
          cond do
            repaired? ->
              nil

            broken? ->
              :repair

            not v1_deployed? ->
              :create

            v1_deployed? and Helper.owner_of(Chains.Base, v1_identity) == deployer ->
              :resume_v1

            bns_needs_v1? ->
              :bns_v1

            true ->
              nil
          end

        if action do
          if action == :repair do
            IO.puts(
              "REPAIR #{name}: broken #{Base16.encode(current_identity)} (owner-only on Base, fleet on L1) -> #{Base16.encode(repair_identity)}"
            )
          end

          {action, name, owner, owner_slot, fleet, v1_salt, v1_identity, repair_salt, repair_identity}
        end
    end
  end
  |> Enum.reject(&is_nil/1)

{repairs, _other} =
  Enum.split_with(work, fn {action, _, _, _, _, _, _, _, _} -> action == :repair end)

IO.puts("Work: #{length(work)} (repairs=#{length(repairs)})")
DetsPlus.sync(:base_cache)

work =
  Enum.shuffle(work)
  |> Enum.chunk_every(1)

for chunk <- work do
  balance = Helper.ensure_gas!(wallet)
  IO.puts("Wallet: #{Base16.encode(deployer)} Balance: #{balance}")

  Enum.each(
    chunk,
    fn {action, name, owner, slot, fleet, v1_salt, v1_identity, repair_salt, _repair_identity} ->
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

          if base_dest != identity or base_owner != owner do
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

          if Helper.null?(base_owner) or base_owner != owner or base_dest != identity do
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

          if Helper.null?(base_owner) or base_owner != owner or base_dest != v1_identity do
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
