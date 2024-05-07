Mix.install(
  [
    {:diode, path: "/home/dominicletz/projects/diode/diode_traffic_relay"},
    {:dets_plus, "~> 2.1"}
  ],
  config: [diode: [no_start: true]]
)

{:ok, _pid} = Supervisor.start_link([{RemoteChain.Sup, Chains.Moonbeam}], strategy: :rest_for_one)
{:ok, _pid} = Supervisor.start_link([{RemoteChain.Sup, Chains.Diode}], strategy: :rest_for_one)
:persistent_term.put(:identity, Secp256k1.generate())
Logger.configure(level: :warning)

storage =
  File.read!("bns_2024_05_06.json")
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
      not String.starts_with?(name, "drive-") and not String.starts_with?(name, "diodetest-") and
      not String.starts_with?(name, "test-")
  end)
  |> Enum.sort()
  |> Enum.uniq()

IO.puts("Names: #{length(names)}")
{:ok, _dets} = DetsPlus.open_file(:moon_cache)

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
        IO.inspect({name, Base16.encode(owner)})

        m_owner =
          case DetsPlus.lookup(:moon_cache, addr) do
            [] ->
              m_owner =
                RemoteChain.RPCCache.get_storage_at(
                  Chains.Moonbeam,
                  "0x8a093e3A83F63A00FFFC4729aa55482845a49294",
                  Base16.encode(addr)
                )
                |> Base16.decode()
                |> Hash.to_address()

              DetsPlus.insert(:moon_cache, [{addr, m_owner}])
              m_owner

            [{^addr, value}] ->
              value
          end

        {name, owner, m_owner, addr}
    end
  end
  |> Enum.filter(fn {_name, owner, m_owner, _addr} -> owner != m_owner end)

IO.puts("Missing: #{length(missing)}")
DetsPlus.sync(:moon_cache)

wallet =
  Wallet.from_privkey(
    Base16.decode(System.get_env("PRIVATE"))
  )

bns = Base16.decode("0x8a093e3A83F63A00FFFC4729aa55482845a49294")
missing = Enum.shuffle(missing) |> Enum.chunk_every(20)

for chunk <- missing do
  nonce =
    RemoteChain.RPC.get_transaction_count(Chains.Moonbeam, Base16.encode(Wallet.address!(wallet)))
    |> Base16.decode_int()

  IO.puts("Wallet: #{Base16.encode(Wallet.address!(wallet))} Nonce: #{nonce}")

  for {{name, owner, _m_owner, addr}, i} <- Enum.with_index(chunk) do
    IO.puts("Register #{name} to #{Base16.encode(owner)} ...")
    Process.sleep(100)

    DetsPlus.delete(:moon_cache, addr)
    DetsPlus.sync(:moon_cache)

    tx1 =
      Shell.transaction(wallet, bns, "Register", ["string", "address"], [name, owner],
        nonce: nonce + i * 2,
        chainId: Chains.Moonbeam.chain_id()
      )

    tx2 =
      Shell.transaction(wallet, bns, "TransferOwner", ["string", "address"], [name, owner],
        nonce: nonce + 1 + i * 2,
        chainId: Chains.Moonbeam.chain_id()
      )

    IO.puts("TX1: Registering #{name} to #{Base16.encode(owner)} ...")
    id1 = IO.inspect(Shell.submit_tx(tx1))
    IO.puts("TX2: Transferring #{name} to #{Base16.encode(owner)} ...")
    id2 = IO.inspect(Shell.submit_tx(tx2))
    [{id1, tx1}, {id2, tx2}]
  end
  |> List.flatten()
  |> Enum.each(&Shell.await_tx_id/1)
end

# IO.inspect({name, Contract.BNS.resolve_entry(name)})
