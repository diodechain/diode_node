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
  @bns Base16.decode("0x87C1D1304944A9EA16AF18CB777E3CEE0D3DACEA")
  @drive_member Base16.decode("0x3D565EC28595C1A0710ABCBD8C0F979D31E38704")

  def factory, do: @factory
  def bns, do: @bns
  def drive_member, do: @drive_member

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

  # Deterministic CREATE2 salt so re-runs find the same identity address.
  # Not the device hmac salt — clients adopt via BNS + owner check.
  def identity_salt(owner), do: Hash.keccak_256(owner)

  def identity_address(owner) do
    salt = identity_salt(owner)
    data = ABI.encode_call("Create2Address", ["bytes32"], [salt]) |> Base16.encode()

    RemoteChain.RPC.call!(Chains.Base, to: Base16.encode(@factory), data: data)
    |> Base16.decode()
    |> Hash.to_address()
  end

  def identity_deployed?(owner) do
    addr = identity_address(owner)
    code = RemoteChain.RPC.get_code(Chains.Base, Base16.encode(addr))
    {addr, Base16.decode(code) != ""}
  end

  def resolve_owner(name) do
    data = ABI.encode_call("ResolveOwner", ["string"], [name]) |> Base16.encode()

    RemoteChain.RPC.call!(Chains.Base, to: Base16.encode(@bns), data: data)
    |> Base16.decode()
    |> Hash.to_address()
  end

  def resolve_destination(name) do
    data = ABI.encode_call("Resolve", ["string"], [name]) |> Base16.encode()

    RemoteChain.RPC.call!(Chains.Base, to: Base16.encode(@bns), data: data)
    |> Base16.decode()
    |> Hash.to_address()
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

missing =
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

        {identity, deployed?, base_owner, base_dest} =
          case DetsPlus.lookup(:base_cache, owner_slot) do
            [{^owner_slot, cached}] ->
              cached

            [] ->
              IO.inspect({name, Base16.encode(owner)})
              {identity, deployed?} = Helper.identity_deployed?(owner)
              base_owner = Helper.resolve_owner(name)
              base_dest = Helper.resolve_destination(name)
              cached = {identity, deployed?, base_owner, base_dest}
              DetsPlus.insert(:base_cache, [{owner_slot, cached}])
              cached
          end

        if not deployed? or base_owner != owner or base_dest != identity do
          {name, owner, identity, deployed?, owner_slot}
        end
    end
  end
  |> Enum.reject(&is_nil/1)

IO.puts("Missing: #{length(missing)}")
DetsPlus.sync(:base_cache)

wallet = Wallet.from_privkey(Base16.decode(String.trim(File.read!("diode_glmr.key"))))

missing =
  Enum.shuffle(missing)
  |> Enum.chunk_every(1)

for chunk <- missing do
  balance = Helper.ensure_gas!(wallet)

  nonce =
    RemoteChain.RPC.get_transaction_count(
      Chains.Base,
      Base16.encode(Wallet.address!(wallet))
    )
    |> Base16.decode_int()

  IO.puts("Wallet: #{Base16.encode(Wallet.address!(wallet))} Nonce: #{nonce} Balance: #{balance}")

  {txs, _next_nonce} =
    Enum.reduce(chunk, {[], nonce}, fn {name, owner, _identity, _deployed?, slot}, {acc, n} ->
      {identity, deployed?} = Helper.identity_deployed?(owner)

      IO.puts(
        "Prepare #{name} owner=#{Base16.encode(owner)} identity=#{Base16.encode(identity)} deployed=#{deployed?} ..."
      )

      Process.sleep(100)
      DetsPlus.delete(:base_cache, slot)
      DetsPlus.sync(:base_cache)

      salt = Helper.identity_salt(owner)

      {acc, n} =
        if deployed? do
          {acc, n}
        else
          IO.puts("TX: Create identity for #{Base16.encode(owner)} ...")

          tx =
            Shell.transaction(
              wallet,
              Helper.factory(),
              "Create",
              ["address", "bytes32", "address"],
              [owner, salt, Helper.drive_member()],
              nonce: n,
              chainId: Chains.Base.chain_id()
            )

          id = Helper.submit_tx(tx)
          {[{id, tx} | acc], n + 1}
        end

      IO.puts("TX: Register #{name} -> #{Base16.encode(identity)} ...")

      tx_reg =
        Shell.transaction(
          wallet,
          Helper.bns(),
          "Register",
          ["string", "address"],
          [name, identity],
          nonce: n,
          chainId: Chains.Base.chain_id()
        )

      id_reg = Helper.submit_tx(tx_reg)

      IO.puts("TX: TransferOwner #{name} -> #{Base16.encode(owner)} ...")

      tx_own =
        Shell.transaction(
          wallet,
          Helper.bns(),
          "TransferOwner",
          ["string", "address"],
          [name, owner],
          nonce: n + 1,
          chainId: Chains.Base.chain_id()
        )

      id_own = Helper.submit_tx(tx_own)

      {[{id_own, tx_own}, {id_reg, tx_reg} | acc], n + 2}
    end)

  txs
  |> Enum.reverse()
  |> Enum.with_index(1)
  |> Enum.each(fn {tx, idx} ->
    IO.puts("Awaiting TX-#{idx} ...")
    Shell.await_tx_id(tx)
  end)
end

# IO.inspect({name, Contract.BNS.resolve_entry(name)})
