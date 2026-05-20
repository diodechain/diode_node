#!/usr/bin/env elixir
Mix.install(
  [
    {:diode, path: __DIR__ <> "/../"},
    {:dets_plus, "~> 2.1"},
    {:globals, "~> 1.1"},
    {:debouncer, "~> 1.0", override: true},
    {:diode_client, path: "../../diode_client_ex", override: true}
  ],
  config: [diode: [no_start: true]]
)

alias DiodeClient.{Secp256k1, Base16, Hash, Wallet}
alias DiodeClient.Contracts.{DriveMember, Factory, BNS}

{:ok, _pid} =
  Supervisor.start_link([{RemoteChain.Sup, Chains.OasisSapphire}], strategy: :rest_for_one)

{:ok, _pid} = Supervisor.start_link([{RemoteChain.Sup, Chains.Diode}], strategy: :rest_for_one)
:persistent_term.put(:identity, Secp256k1.generate())
Logger.configure(level: :warning)

defmodule Helper do
  require Logger

  def submit_tx(tx, retries \\ 30, check \\ false) do
    if retries == 0 do
      raise "Failed to submit transaction after #{retries} retries"
    end

    if check do
      Shell.call_tx!(tx, "latest")
    end

    Shell.submit_tx(tx)
    |> case do
      tx_id when is_binary(tx_id) ->
        IO.inspect(DiodeClient.Transaction.hash(tx) |> Base16.encode())

        tx_id
        |> IO.inspect()

      {:error, error} ->
        Logger.error("Failed to submit transaction: #{inspect(error)}, retrying... in 10 seconds")
        Process.sleep(10_000)
        submit_tx(tx, retries - 1)
    end
  end

  @max_retries 10
  def await_tx(shell, tx_hash, n \\ @max_retries)

  def await_tx(_shell, _tx_hash, 0) do
    IO.puts("Transaction failed after #{@max_retries} retries")
    exit(1)
  end

  def await_tx(shell, tx_hash, n) do
    shell.get_transaction_receipt(tx_hash)
    |> case do
      %{"status" => "0x1"} ->
        IO.puts("Transaction successful")
        # Just add one more block
        Process.sleep(10_000)

      %{"status" => "0x0"} ->
        IO.puts("Transaction failed")
        exit(1)

      nil ->
        IO.puts("awaiting 6 seconds #{n}")
        Process.sleep(6_000)
        await_tx(shell, tx_hash, n - 1)

      other ->
        IO.puts("Unknown transaction receipt: #{inspect(other)} ... awaiting 6 seconds #{n}")
        Process.sleep(6_000)
        await_tx(shell, tx_hash, n - 1)
    end
  end
end

[name] = System.argv()
deployer_wallet = Wallet.from_privkey(Base16.decode(String.trim(File.read!("diode_glmr.key"))))

wallet =
  Wallet.from_privkey(Hash.keccak_256(name <> "_" <> Wallet.privkey!(deployer_wallet) <> "****"))

IO.puts("Wallet: #{Base16.encode(Wallet.address!(wallet))}")
DiodeClient.interface_add(wallet)

IO.puts("Checking #{name} ...")
diode_full_name = "#{name}.diode"

diode_entry = %{
  owner: BNS.resolve_name_owner(diode_full_name),
  destination: BNS.resolve_name(diode_full_name)
}

IO.inspect(Base16.encode(diode_entry.owner), label: "diode l1 bns owner")
IO.inspect(Base16.encode(diode_entry.destination), label: "diode l1 bns destination")

if diode_entry.owner == DiodeClient.Hash.to_address(0) do
  IO.puts("Diode owner is nil, did you enter the correct name?")
  exit(0)
end

diode_root = DiodeClient.Shell.get_account_root(diode_entry.destination)
# IO.inspect(Base16.encode(diode_root), label: "diode id root")

if diode_root == nil do
  IO.puts("Diode root is nil nothing to do...")
  exit(0)
end

diode_id_members = DriveMember.members(DiodeClient.Shell, diode_entry.destination, nil)
diode_id_owner = DriveMember.owner(DiodeClient.Shell, diode_entry.destination, nil)
IO.inspect(Enum.map(diode_id_members, &Base16.encode/1), label: "diode id members")
IO.inspect(Base16.encode(diode_id_owner), label: "diode id owner")
# IO.inspect("owner is id owner: #{diode_entry.owner == diode_id_owner}")
# IO.inspect("id owner is member: #{diode_id_owner in diode_id_members}")

oasis_full_name = "#{name}.sapphire"
oasis_entry = BNS.resolve_entry(oasis_full_name, "latest")
IO.inspect(Base16.encode(oasis_entry.owner), label: "oasis bns owner")
IO.inspect(Base16.encode(oasis_entry.destination), label: "oasis bns destination")

if oasis_entry.owner == DiodeClient.Hash.to_address(0) do
  IO.puts("Oasis bns owner is nil, this name is not registered in the BNS?")
  exit(0)
end

oasis_root = DiodeClient.Shell.get_account_root(oasis_entry.destination)
# IO.inspect(Base16.encode(oasis_root), label: "oasis id root")

new_id_address = Factory.identity_address(DiodeClient.Shell.OasisSapphire)

if oasis_root != nil and oasis_entry.destination != new_id_address do
  IO.puts("Oasis identity is already a different identity, skipping...")
  exit(0)
end

if oasis_root == nil do
  IO.puts("New ID address: #{Base16.encode(new_id_address)}")

  new_oasis_root = DiodeClient.Shell.OasisSapphire.get_account_root(new_id_address)
  IO.inspect(Base16.encode(new_oasis_root), label: "new oasis root")

  if new_oasis_root == nil do
    IO.puts("Oasis root is nil need to create the identity...")
    identity_request = Factory.create_identity_request(DiodeClient.Shell.OasisSapphire)

    {["ok", tx_hash], _tx} = DiodeClient.Shell.OasisSapphire.send_transaction(identity_request)
    IO.puts("Awaiting transaction #{tx_hash} ...")
    Helper.await_tx(DiodeClient.Shell.OasisSapphire, tx_hash)
  end
end

oasis_id_owner = DriveMember.owner(DiodeClient.Shell.OasisSapphire, new_id_address, nil)
IO.inspect(Base16.encode(oasis_id_owner), label: "oasis id owner")

oasis_members = DriveMember.members(DiodeClient.Shell.OasisSapphire, new_id_address, nil)
IO.inspect(Enum.map(oasis_members, &Base16.encode/1), label: "oasis members")

missing_members = Enum.filter(diode_id_members, fn member -> member not in oasis_members end)
IO.inspect(Enum.map(missing_members, &Base16.encode/1), label: "missing members")

if Wallet.address!(wallet) in [oasis_entry.owner | oasis_members] do
  for member <- missing_members do
    IO.puts("Adding member #{Base16.encode(member)} to the identity...")

    {["ok", tx_hash], _tx} =
      DriveMember.add_member(DiodeClient.Shell.OasisSapphire, new_id_address, member,
        meta_transaction: true,
        identity: new_id_address
      )

    Helper.await_tx(DiodeClient.Shell.OasisSapphire, tx_hash)
  end
else
  if missing_members != [] do
    IO.puts("Missing members found, but can't add them...")
  end
end

# not doing this anymore,
# if oasis_id_owner != diode_id_owner do
#   IO.puts("Transferring ownership of the identity to the diode owner...")

#   {["ok", tx_hash], _tx} =
#     DriveMember.transfer_ownership(
#       DiodeClient.Shell.OasisSapphire,
#       new_id_address,
#       diode_id_owner,
#       meta_transaction: true,
#       identity: new_id_address
#     )

#   Helper.await_tx(DiodeClient.Shell.OasisSapphire, tx_hash)
# end

if oasis_entry.destination != new_id_address do
  IO.puts("Updating BNS entry for '#{name}' to point to the new identity...")

  nonce =
    RemoteChain.RPC.get_transaction_count(
      Chains.OasisSapphire,
      Base16.encode(Wallet.address!(deployer_wallet))
    )
    |> Base16.decode_int()

  tx =
    Shell.transaction(
      deployer_wallet,
      Base16.decode("0x6cbf10355F8a16F7cd2F7aa762c08374959cE1bD"),
      "Register",
      ["string", "address"],
      [name, new_id_address],
      chainId: Chains.OasisSapphire.chain_id(),
      nonce: nonce
    )

  id = Helper.submit_tx(tx, 30, false)
  Shell.await_tx_id({id, tx})
end

IO.puts("Done")
