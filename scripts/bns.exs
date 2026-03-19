Mix.install(
  [
    {:diode, path: __DIR__ <> "/../"},
    {:dets_plus, "~> 2.1"}
  ],
  config: [diode: [no_start: true]]
)

alias DiodeClient.{Secp256k1, Base16, Hash, Wallet}

{:ok, _pid} =
  Supervisor.start_link([{RemoteChain.Sup, Chains.OasisSapphire}], strategy: :rest_for_one)

{:ok, _pid} = Supervisor.start_link([{RemoteChain.Sup, Chains.Diode}], strategy: :rest_for_one)
:persistent_term.put(:identity, Secp256k1.generate())
Logger.configure(level: :warning)

defmodule Helper do
  require Logger

  def submit_tx(tx, retries \\ 30) do
    if retries == 0 do
      raise "Failed to submit transaction after #{retries} retries"
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
      not String.starts_with?(name, "test-")
  end)
  |> Enum.sort()
  |> Enum.uniq()

IO.puts("Names: #{length(names)}")
{:ok, _dets} = DetsPlus.open_file(:oasis_cache)

missing =
  for name <- names do
    name_hash = Hash.keccak_256(name)
    base = Hash.to_bytes32(1)

    addr =
      Hash.keccak_256(name_hash <> base)
      |> :binary.decode_unsigned()
      |> Kernel.+(1)
      |> :binary.encode_unsigned()

    case Map.get(storage, addr) do
      nil ->
        {nil, nil, nil, nil}

      owner ->
        owner = Hash.to_address(owner)

        m_owner =
          case DetsPlus.lookup(:oasis_cache, addr) do
            [] ->
              IO.inspect({name, Base16.encode(owner)})

              m_owner =
                RemoteChain.RPCCache.get_storage_at(
                  Chains.OasisSapphire,
                  "0x8a093e3A83F63A00FFFC4729aa55482845a49294",
                  Base16.encode(addr)
                )
                |> Base16.decode()
                |> Hash.to_address()

              DetsPlus.insert(:oasis_cache, [{addr, m_owner}])
              m_owner

            [{^addr, value}] ->
              value
          end

        {name, owner, m_owner, addr}
    end
  end
  |> Enum.filter(fn {_name, owner, m_owner, _addr} -> owner != m_owner end)

IO.puts("Missing: #{length(missing)}")
DetsPlus.sync(:oasis_cache)

wallet = Wallet.from_privkey(Base16.decode(String.trim(File.read!("diode_glmr.key"))))

bns = Base16.decode("0x6cbf10355F8a16F7cd2F7aa762c08374959cE1bD")

missing =
  Enum.shuffle(missing)
  |> Enum.take(1123)
  |> Enum.chunk_every(1)

for chunk <- missing do
  nonce =
    RemoteChain.RPC.get_transaction_count(
      Chains.OasisSapphire,
      Base16.encode(Wallet.address!(wallet))
    )
    |> Base16.decode_int()

  IO.puts("Wallet: #{Base16.encode(Wallet.address!(wallet))} Nonce: #{nonce}")

  for {{name, owner, _m_owner, addr}, i} <- Enum.with_index(chunk) do
    IO.puts("Register #{name} to #{Base16.encode(owner)} ...")
    Process.sleep(100)

    DetsPlus.delete(:oasis_cache, addr)
    DetsPlus.sync(:oasis_cache)

    tx1 =
      Shell.transaction(wallet, bns, "Register", ["string", "address"], [name, owner],
        nonce: nonce + i * 2,
        chainId: Chains.OasisSapphire.chain_id()
      )

    tx2 =
      Shell.transaction(wallet, bns, "TransferOwner", ["string", "address"], [name, owner],
        nonce: nonce + 1 + i * 2,
        chainId: Chains.OasisSapphire.chain_id()
      )

    IO.puts("TX-1: Registering #{name} to #{Base16.encode(owner)} ...")
    id1 = Helper.submit_tx(tx1)
    IO.puts("TX-2: Transferring #{name} to #{Base16.encode(owner)} ...")
    id2 = Helper.submit_tx(tx2)
    [{id1, tx1}, {id2, tx2}]
  end
  |> List.flatten()
  |> Enum.reverse()
  |> Enum.with_index(1)
  |> Enum.reverse()
  |> Enum.each(fn {tx, idx} ->
    IO.puts("Awaiting TX-#{idx} ...")
    Shell.await_tx_id(tx)
  end)
end

# IO.inspect({name, Contract.BNS.resolve_entry(name)})
