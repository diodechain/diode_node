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

  def fetch_nonce(wallet) do
    latest =
      RemoteChain.RPC.get_transaction_count(
        Chains.Base,
        Base16.encode(Wallet.address!(wallet)),
        "latest"
      )
      |> Base16.decode_int()

    pending =
      RemoteChain.RPC.get_transaction_count(
        Chains.Base,
        Base16.encode(Wallet.address!(wallet)),
        "pending"
      )
      |> Base16.decode_int()

    max(latest, pending)
  end

  def gas_price(bump \\ 0) do
    price =
      RemoteChain.RPC.gas_price(Chains.Base)
      |> Base16.decode_int()

    # bump is in percent, e.g. 20 => +20%
    price + div(price * bump, 100)
  end

  def submit_and_await(wallet, build_fn, nonce, retries \\ 30, gas_bump \\ 0)

  def submit_and_await(_wallet, _build_fn, _nonce, 0, _gas_bump) do
    raise "Failed to submit transaction after retries exhausted"
  end

  def submit_and_await(wallet, build_fn, nonce, retries, gas_bump) do
    tx = build_fn.(nonce, gas_price(gas_bump))
    tx_hash = DiodeClient.Transaction.hash(tx) |> Base16.encode()

    # Simulate first — avoid paying gas for calls that will revert.
    case Shell.call_tx(tx, "latest") do
      {:error, error} ->
        {:error, {:would_revert, error}}

      {:ok, _} ->
        do_submit_and_await(wallet, build_fn, nonce, retries, gas_bump, tx, tx_hash)
    end
  end

  defp do_submit_and_await(wallet, build_fn, nonce, retries, gas_bump, tx, tx_hash) do
    Shell.submit_tx(tx)
    |> case do
      tx_id when is_binary(tx_id) ->
        IO.inspect(tx_hash)
        IO.inspect(tx_id)

        case await_success!(tx_id, tx) do
          :ok -> {:ok, nonce + 1}
          {:error, reason} -> {:error, reason}
        end

      :already_known ->
        IO.puts("TX already known #{tx_hash}, awaiting...")

        case await_success!(tx_hash, tx) do
          :ok -> {:ok, fetch_nonce(wallet)}
          {:error, reason} -> {:error, reason}
        end

      {:error, error} ->
        if out_of_gas_error?(error) do
          raise "Out of gas / insufficient funds, stopping: #{inspect(error)}"
        end

        Logger.error("Failed to submit transaction: #{inspect(error)}, retrying...")

        cond do
          nonce_error?(error) ->
            Process.sleep(2_000)
            next = max(fetch_nonce(wallet), parse_next_nonce(error) || 0)
            next_bump = if underpriced_error?(error), do: gas_bump + 50, else: gas_bump
            IO.puts("Refreshing nonce #{nonce} -> #{next} (gas_bump=#{next_bump}%)")
            submit_and_await(wallet, build_fn, next, retries - 1, next_bump)

          true ->
            Process.sleep(10_000)
            submit_and_await(wallet, build_fn, nonce, retries - 1, gas_bump)
        end
    end
  end

  def await_success!(tx_id, tx) do
    Shell.await_tx_id({tx_id, tx})

    case RemoteChain.RPC.rpc(Chains.Base, "eth_getTransactionReceipt", [tx_id]) do
      {:ok, %{"status" => "0x1"}} ->
        :ok

      {:ok, %{"status" => "0x0"} = receipt} ->
        {:error, {:reverted, tx_id, receipt["gasUsed"]}}

      {:ok, nil} ->
        Process.sleep(2_000)
        await_success!(tx_id, tx)

      other ->
        {:error, {:bad_receipt, tx_id, other}}
    end
  end

  def zero_address, do: Hash.to_address(0)

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

  def ensure_gas!(wallet) do
    balance = Shell.get_balance(Chains.Base, Wallet.address!(wallet))

    # 1 finney == 0.001 ether; Shell.ether/1 only accepts integers
    if balance < Shell.finney(1) do
      raise "Out of gas / insufficient funds, stopping: balance=#{balance} wei (#{Base16.encode(Wallet.address!(wallet))})"
    end

    balance
  end

  defp error_message(error) do
    cond do
      is_binary(error) -> error
      is_map(error) -> "#{Map.get(error, "message", "")} #{inspect(error)}"
      true -> inspect(error)
    end
    |> String.downcase()
  end

  defp out_of_gas_error?(error) do
    message = error_message(error)

    String.contains?(message, "insufficient funds") or
      String.contains?(message, "out of gas") or
      String.contains?(message, "gas required exceeds") or
      String.contains?(message, "max fee per gas less than block base fee")
  end

  defp nonce_error?(error) do
    message = error_message(error)

    String.contains?(message, "nonce too low") or
      String.contains?(message, "already known") or
      underpriced_error?(error)
  end

  defp underpriced_error?(error) do
    message = error_message(error)

    String.contains?(message, "replacement transaction underpriced") or
      String.contains?(message, "underpriced")
  end

  defp parse_next_nonce(error) do
    message = error_message(error)

    case Regex.run(~r/next nonce\s+(\d+)/, message) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
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

    case RemoteChain.RPC.call(Chains.Base, to: Base16.encode(@bns), data: data) do
      {:ok, ret} -> {:ok, ret |> Base16.decode() |> Hash.to_address()}
      {:error, error} -> {:error, error}
    end
  end

  def resolve_destination(name) do
    data = ABI.encode_call("Resolve", ["string"], [name]) |> Base16.encode()

    case RemoteChain.RPC.call(Chains.Base, to: Base16.encode(@bns), data: data) do
      {:ok, ret} -> {:ok, ret |> Base16.decode() |> Hash.to_address()}
      {:error, error} -> {:error, error}
    end
  end
end

# curl -k -H "Content-Type: application/json" -X POST --data '{"jsonrpc":"2.0","method":"eth_getStorage","params":["0xaf60faa5cd840b724742f1af116168276112d6a6", "latest"],"id":73}' https://prenet.diode.io:8443 > bns_2026_08_01.json

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

IO.puts("Names: #{length(names)}")
{:ok, _dets} = DetsPlus.open_file(:base_cache)

wallet = Wallet.from_privkey(Base16.decode(String.trim(File.read!("diode_glmr.key"))))
deployer = Wallet.address!(wallet)

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

        case DetsPlus.lookup(:base_cache, owner_slot) do
          [{^owner_slot, status}]
          when status in [:invalid, :foreign_owner, :owner_controlled, :done] ->
            nil

          [{^owner_slot, {identity, deployed?, base_owner, base_dest}}] ->
            case Helper.classify_name(deployer, owner, identity, base_owner, base_dest) do
              :migratable ->
                if not deployed? or base_owner != owner or base_dest != identity do
                  {name, owner, identity, deployed?, owner_slot}
                end

              other ->
                DetsPlus.insert(:base_cache, [{owner_slot, other}])
                nil
            end

          [] ->
            IO.inspect({name, Base16.encode(owner)})
            {identity, deployed?} = Helper.identity_deployed?(owner)

            with {:ok, base_owner} <- Helper.resolve_owner(name),
                 {:ok, base_dest} <- Helper.resolve_destination(name) do
              case Helper.classify_name(deployer, owner, identity, base_owner, base_dest) do
                :migratable ->
                  cached = {identity, deployed?, base_owner, base_dest}
                  DetsPlus.insert(:base_cache, [{owner_slot, cached}])

                  if not deployed? or base_owner != owner or base_dest != identity do
                    {name, owner, identity, deployed?, owner_slot}
                  end

                other ->
                  IO.puts(
                    "Skipping #{inspect(name)} (#{other}): base_owner=#{Base16.encode(base_owner)} dest=#{Base16.encode(base_dest)}"
                  )

                  DetsPlus.insert(:base_cache, [{owner_slot, other}])
                  nil
              end
            else
              {:error, error} ->
                IO.puts(
                  "Skipping invalid name #{inspect(name)}: Base BNS resolve reverted (#{inspect(error)})"
                )

                DetsPlus.insert(:base_cache, [{owner_slot, :invalid}])
                nil
            end
        end
    end
  end
  |> Enum.reject(&is_nil/1)

IO.puts("Missing: #{length(missing)}")
DetsPlus.sync(:base_cache)

missing = Enum.shuffle(missing)
nonce = Helper.fetch_nonce(wallet)

Enum.reduce(missing, nonce, fn {name, owner, _identity, _deployed?, slot}, nonce ->
  balance = Helper.ensure_gas!(wallet)
  nonce = max(nonce, Helper.fetch_nonce(wallet))

  {identity, deployed?} = Helper.identity_deployed?(owner)

  IO.puts("Wallet: #{Base16.encode(deployer)} Nonce: #{nonce} Balance: #{balance}")

  with {:ok, base_owner} <- Helper.resolve_owner(name),
       {:ok, base_dest} <- Helper.resolve_destination(name) do
    case Helper.classify_name(deployer, owner, identity, base_owner, base_dest) do
      :done ->
        IO.puts("Already done #{name}, skipping")
        DetsPlus.insert(:base_cache, [{slot, :done}])
        DetsPlus.sync(:base_cache)
        nonce

      :foreign_owner ->
        IO.puts(
          "Skipping foreign-owned #{name}: base_owner=#{Base16.encode(base_owner)} (not deployer)"
        )

        DetsPlus.insert(:base_cache, [{slot, :foreign_owner}])
        DetsPlus.sync(:base_cache)
        nonce

      :owner_controlled ->
        IO.puts(
          "Skipping owner-controlled #{name}: L1 owner already owns on Base but dest=#{Base16.encode(base_dest)} (need owner to update)"
        )

        DetsPlus.insert(:base_cache, [{slot, :owner_controlled}])
        DetsPlus.sync(:base_cache)
        nonce

      :migratable ->
        IO.puts(
          "Prepare #{name} owner=#{Base16.encode(owner)} identity=#{Base16.encode(identity)} deployed=#{deployed?} base_owner=#{Base16.encode(base_owner)} ..."
        )

        Process.sleep(100)
        salt = Helper.identity_salt(owner)

        result =
          with {:ok, nonce} <-
                 (if deployed? do
                    {:ok, nonce}
                  else
                    IO.puts("TX: Create identity for #{Base16.encode(owner)} ...")

                    Helper.submit_and_await(
                      wallet,
                      fn n, gas_price ->
                        Shell.transaction(
                          wallet,
                          Helper.factory(),
                          "Create",
                          ["address", "bytes32", "address"],
                          [owner, salt, Helper.drive_member()],
                          nonce: n,
                          gasPrice: gas_price,
                          chainId: Chains.Base.chain_id()
                        )
                      end,
                      nonce
                    )
                  end),
               {:ok, nonce} <-
                 (if base_dest == identity and base_owner in [deployer, Helper.zero_address()] do
                    {:ok, nonce}
                  else
                    IO.puts("TX: Register #{name} -> #{Base16.encode(identity)} ...")

                    Helper.submit_and_await(
                      wallet,
                      fn n, gas_price ->
                        Shell.transaction(
                          wallet,
                          Helper.bns(),
                          "Register",
                          ["string", "address"],
                          [name, identity],
                          nonce: n,
                          gasPrice: gas_price,
                          chainId: Chains.Base.chain_id()
                        )
                      end,
                      nonce
                    )
                  end),
               {:ok, nonce} <-
                 (if owner == deployer do
                    {:ok, nonce}
                  else
                    IO.puts("TX: TransferOwner #{name} -> #{Base16.encode(owner)} ...")

                    Helper.submit_and_await(
                      wallet,
                      fn n, gas_price ->
                        Shell.transaction(
                          wallet,
                          Helper.bns(),
                          "TransferOwner",
                          ["string", "address"],
                          [name, owner],
                          nonce: n,
                          gasPrice: gas_price,
                          chainId: Chains.Base.chain_id()
                        )
                      end,
                      nonce
                    )
                  end) do
            DetsPlus.insert(:base_cache, [{slot, :done}])
            DetsPlus.sync(:base_cache)
            {:ok, nonce}
          end

        case result do
          {:ok, nonce} ->
            nonce

          {:error, reason} ->
            IO.puts("Skipping #{name} after TX failure: #{inspect(reason)}")
            DetsPlus.insert(:base_cache, [{slot, :invalid}])
            DetsPlus.sync(:base_cache)
            max(nonce, Helper.fetch_nonce(wallet))
        end
    end
  else
    {:error, error} ->
      IO.puts("Skipping #{name}: resolve failed #{inspect(error)}")
      DetsPlus.insert(:base_cache, [{slot, :invalid}])
      DetsPlus.sync(:base_cache)
      nonce
  end
end)

# IO.inspect({name, Contract.BNS.resolve_entry(name)})
