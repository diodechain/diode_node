# Scratchpade February 16th 2024

m1bns = Hash.to_address(0x75140F88B0F4B2FBC6DADC16CC51203ADB07FE36)
Moonbeam.get_storage_at(Base16.encode(m1bns), Base16.encode(3, false))

# Scratchpade February 14th 2024

block_Wait = 175200
now = 6808809
end_stake = 6984009 ~ March 14th

## Sending 50k Diode from US1 to US2
addr = "0x7e4cd38d266902444dc9c8f7c0aa716a32497d0b" |> Base16.decode
Shell.transfer_from(Diode.miner, addr, value: Shell.ether(50_000))

## Staking 50k Diode on US2
Shell.call_from(Diode.miner, Diode.registry_address, "MinerStake", [], [], value: Shell.ether(50_000))
Shell.submit_from(Diode.miner, Diode.registry_address, "MinerStake", [], [], value: Shell.ether(50_000))

## Unstaking on US1

Shell.call_from(Diode.miner, Diode.registry_address, "MinerUnstake", ["uint256"], [Shell.ether(2_380_000)])
Shell.submit_from(Diode.miner, Diode.registry_address, "MinerUnstake", ["uint256"], [Shell.ether(2_380_000)])

## Checking pending funds
miner_value = for i <- 0..3, do: Contract.Registry.miner_value(i, Diode.miner, Chain.peak)

## Unstaking on EU1
Shell.call_from(Diode.miner, Diode.registry_address, "MinerUnstake", ["uint256"], [Shell.ether(2_050_000)])
Shell.submit_from(Diode.miner, Diode.registry_address, "MinerUnstake", ["uint256"], [Shell.ether(2_050_000)])
miner_value = for i <- 0..3, do: Contract.Registry.miner_value(i, Diode.miner, Chain.peak)

## Sending 50k Diode from AS1 to AS2
addr = "0x1350d3b501d6842ed881b59de4b95b27372bfae8" |> Base16.decode
Shell.transfer_from(Diode.miner, addr, value: Shell.ether(50_000))

## Unstaking on AS1
Shell.call_from(Diode.miner, Diode.registry_address, "MinerUnstake", ["uint256"], [Shell.ether(2_000_000)])
Shell.submit_from(Diode.miner, Diode.registry_address, "MinerUnstake", ["uint256"], [Shell.ether(2_000_000)])
miner_value = for i <- 0..3, do: Contract.Registry.miner_value(i, Diode.miner, Chain.peak)

## Sending 50k from fc1 to EU2
Shell.transfer_from(fc1, eu2, value: Shell.ether(50_000))

## Staking 50k on EU2
Shell.call_from(Diode.miner, Diode.registry_address, "MinerStake", [], [], value: Shell.ether(50_000))
Shell.submit_from(Diode.miner, Diode.registry_address, "MinerStake", [], [], value: Shell.ether(50_000))

# Scratchpade January 29th 2024
state_a = Model.ChainSql.state(hd(BlockProcess.fetch(6729001, [:hash])))
state_b = Model.ChainSql.state(hd(BlockProcess.fetch(6729128, [:hash])))

state_a.accounts |> Enum.count(fn {_, acc} -> acc.root_hash == nil end)
state_b.accounts |> Enum.count(fn {_, acc} -> acc.root_hash == nil end)

diff = Chain.State.difference(state_a, state_b)
state_b2 = Chain.State.apply_difference(state_a, diff)
state_b2.accounts |> Enum.count(fn {_, acc} -> acc.root_hash == nil end)


block_number = 6729001
[hash] = BlockProcess.fetch(block_number, [:hash])
state = Model.ChainSql.state(hash)
state.accounts |> Enum.count(fn {_, acc} -> acc.root_hash == nil end)

:timer.tc(fn -> state |> Chain.State.tree() |> MerkleTree.merkle() end) |> elem(0)





# Scratchpad January 27th 2024

for x <- 1..500 do
    Process.sleep(10)
    spawn(fn ->
        child = self()
        spawn(fn ->
            Chain.with_peak(fn _b ->
                send(child, {:pid, self()})
                receive do
                    :stop -> :ok
                end
                IO.puts("#{x}")
            end)
        end)
        pid = receive do
            {:pid, pid} -> pid
        end
        receive do
            :stop -> send(pid, :stop)
        end
    end)
end |> Enum.map(fn pid ->
    send(pid, :stop)
end)

# Scratchpad January 25th 2024

SC[31m13:41:59.140 [error] GenServer Chain terminating
** (stop) exited in: GenServer.call(BlockProcess, {:with_worker, <<0, 0, 128, 211, 98, 25, 154, 120, 93, 11, 95, 143, 242, 25, 139, 175, 232, 235, 65, 124, 184, 158,
 146, 15, 145, 160, 52, 84, 116, 139, 33, 220>>, #Function<15.48600449/1 in Model.ChainSql.set_normative/2>}, 120000)
    ** (EXIT) time out
    (elixir 1.13.4) lib/gen_server.ex:1030: GenServer.call/3
    (Elixir.Diode 1.0.8) lib/block_process.ex:355: BlockProcess.do_with_worker/2
    (Elixir.Diode 1.0.8) lib/model/chainsql.ex:261: Model.ChainSql.set_normative/2
    (Elixir.Diode 1.0.8) lib/chain.ex:332: anonymous fn/5 in Chain.handle_call/3
    (stdlib 4.3) timer.erl:235: :timer.tc/1
    (Elixir.Diode 1.0.8) lib/stats.ex:44: Stats.tc!/2
    (Elixir.Diode 1.0.8) lib/stats.ex:35: Stats.tc/2
    (stdlib 4.3) gen_server.erl:1149: :gen_server.try_handle_call/4
    (stdlib 4.3) gen_server.erl:1178: :gen_server.handle_msg/6
    (stdlib 4.3) proc_lib.erl:240: :proc_lib.init_p_do_apply/3
Last message (from :active_sync_job): {:add_block, <<0, 0, 39, 150, 176, 117, 236, 98, 243, 22, 91, 46, 195, 213, 15, 212, 171, 222, 34, 109, 197, 216, 76, 83, 210, 
68, 251, 168, 151, 213, 140, 108>>, <<0, 0, 128, 211, 98,


# Scratchpad January 18th 2024

bns = BlockProcess.with_account(peak, Contract.BNS.address(), fn acc -> acc end)

peak = Chain.peak()
accounts = BlockProcess.with_state(peak, fn state -> Map.keys(Chain.State.accounts(state)) end)
File.write!("accounts.csv", Enum.map(accounts, &Base16.encode/1) |> Enum.join("\n"))


all = Chain.Account.tree(bns) |> MerkleTree.to_list |> Map.new()

add = fn bin, n -> 
    n = :binary.decode_unsigned(bin) + n
    <<n::unsigned-big-size(256)>>
end

names = Enum.map(all, fn {key, <<value::binary-size(30), _len::unsigned-size(16)>>} -> {key, String.trim(value, <<0>>)} end) |> Enum.filter(fn {_, value} -> byte_size(value) > 7 and List.ascii_printable?(:binary.bin_to_list(value)) end) |> Enum.map(fn {addr, name} -> %{
    addr: addr,
    name: name,
    owner: Map.get(all, add.(addr, -1)),
    destination: Map.get(all, add.(addr, -2)),
} end) |> Enum.filter(fn %{owner: owner} -> owner != nil end)


devices = Model.Sql.query!(Model.KademliaSql, "SELECT object FROM p2p_objects", []) |> Enum.map(fn [object: obj] -> BertInt.decode!(obj) |> Object.decode!() end) |> Enum.filter(fn obj -> elem(obj, 0) == :ticket end) |> Enum.map(fn obj -> Object.TicketV1.device_address(obj) end)

devices_v2 = Model.Sql.query!(Model.KademliaSql, "SELECT object FROM p2p_objects", []) |> Enum.map(fn [object: obj] -> BertInt.decode!(obj) |> Object.decode!() end) |> Enum.filter(fn obj -> elem(obj, 0) == :ticket end) |> Enum.map(fn obj -> {Object.TicketV1.device_address(obj), case Object.TicketV1.local_address(obj) do
    <<b, _rest::binary>> when b in [0, 1] -> "diode_drive"
    "spam" -> "test"
    _ -> "diode_cli"
end} end)

File.write!("devices.csv", Enum.map(devices_v2, fn {addr, type} -> Base16.encode(addr) <> " #{type}\n" end) |> Enum.join(""))

for x in {as,us,eu}{1,2} as3; do scp -C $x:/opt/diode/devices.csv devices-$x.csv; done
cat devices-* | sort | uniq > devices.csv



# Scratchpad January 9th 2024

```elixir
peak = Chain.peak()
balances = BlockProcess.with_state(peak, fn state ->
    for {key, account} <- state.accounts do
        {key, account.balance}
    end
end)

stakes = for {address, balance} <- balances do
    miner_value = for i <- 0..3, do: Contract.Registry.miner_value(i, address, peak)
    fleet_value = for i <- 0..3, do: Contract.Registry.fleet_value(i, address, peak)
    {address, balance, miner_value, fleet_value}
end


print = fn str -> File.write!("accounts.csv", str <> "\n", [:append]) end

print.("Address, Balance, MStaked, MPending, MLocked, MClaimable, FStaked, FPending, FLocked, FClaimable")

for {address, balance, [m0,m1,m2,m3], [f0,f1,f2,f3]} <- stakes do
    z = [balance, m0,m1,m2,m3, f0,f1,f2,f3]
    if Enum.any?(z, fn n -> n > 0 end) do
        print.("#{Base16.encode(address)}, #{balance}, #{m0}, #{m1}, #{m2}, #{m3}, #{f0}, #{f1}, #{f2}, #{f3}")
    end
end

```

# Scratchpad Dec 19th

alias Chain.Block
block = BlockProcess.with_block(6512534, fn block -> block end) 
Diode.hash(Block.encode_transactions(Block.transactions(block))) == Block.txhash(block)

# Scratchpad Nov 20th

Process.exit(Process.whereis(BlockProcess), :random)


bp = :sys.get_state(Process.whereis(BlockProcess))
Map.values(bp.waiting) |> List.flatten |> Enum.map(fn {pid, _ref} -> Process.alive?(pid) end)

# Command line perf testing reference

## 21. Feb 2022 - e97191192cc022452d2167beea24f06939cac6f8

```elixir
rpc = fn method, args -> :timer.tc(fn -> Network.EdgeV2.handle_async_msg([method, Rlpx.num2bin(Chain.peak()) | args], nil) end) end
id = <<237, 217, 116, 65, 255, 170, 122, 217, 206, 132, 246, 126, 210, 93, 83, 13, 230, 107, 130, 135>>
slot1 = <<5, 127, 142, 10, 91, 52, 106, 14, 9, 229, 29, 19, 3, 97, 232, 18, 212, 29, 88, 37, 185, 216, 147, 129, 123, 167, 254, 18, 252, 9, 230, 157>>
slot2 = <<27, 241, 228, 27, 25, 19, 64, 172, 238, 203, 185, 176, 129, 254, 154, 178, 131, 5, 167, 1, 226, 25, 216, 229, 150, 121, 1, 130, 59, 28, 70, 179>>
slot3 = <<27, 241, 228, 27, 25, 19, 64, 172, 238, 203, 185, 176, 129, 254, 154, 178, 131, 5, 167, 1, 226, 25, 216, 229, 150, 121, 1, 130, 59, 28, 70, 180>>
slot4 = <<27, 241, 228, 27, 25, 19, 64, 172, 238, 203, 185, 176, 129, 254, 154, 178, 131, 5, 167, 1, 226, 25, 216, 229, 150, 121, 1, 130, 59, 28, 70, 181>>

> :timer.tc(fn -> Chain.with_peak(&Chain.Block.blockquick_window/1) end) |> elem(0)
324

> rpc.("getstateroots", []) |> elem(0)
124

> rpc.("getaccount", [id]) |> elem(0)
200

> rpc.("getaccountroots", [id]) |> elem(0)
900

> rpc.("getaccountvalue", [id, slot1]) |> elem(0)
> rpc.("getaccountvalue", [id, slot2]) |> elem(0)
900

> rpc.("getaccountvalues", [id, slot1, slot2, slot3, slot4]) |> elem(0)
1000

> :timer.tc(fn ->
    rpc.("getaccountvalue", [id, slot1])
    rpc.("getaccountvalue", [id, slot2])
    rpc.("getaccountvalue", [id, slot3])
    rpc.("getaccountvalue", [id, slot4])
end) |> elem(0)
4000

## 2nd Aug 2023 BNS 

bns = Hash.to_address(0xAF60FAA5CD840B724742F1AF116168276112D6A6)
rpc.("getaccountroots", [bns]) |> elem(0)

```
