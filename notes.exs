# Jul 2nd
[0 ]                            1=3d565ec28595c1a0710abcbd8c0f979d31e38704 Wallet                     80-DUP1
[1 ] 30743 "CALL"               2=d78653669fd3df4df8f3141ffa53462121d117a4 Proxy (DiodeRegistryLight) HIT
[2 ]   31497 "DELEGATECALL"     3=0b7d294ef304d41e10b965447857d0654e6e52a5 DiodeRegistryLight         B4-INVALID
[3 ]     34597 "STATICCALL"     4=8afe08d333f785c818199a5bdc7a52ac6ffc492a Proxy (DevFleetContract)   57-JUMPI
[4 ]       35348 "DELEGATECALL" 5=75637505b914ec9c6e9b8ede383605cd117b0c99 DevFleetContract           03-SUB
[n4]       36858 "RETURN"
[n3]     37162 "RETURN"
[n2]   48214 "REVERT"
[xx] 49656 "STOP"


"pc": 7653,
"pc": 175,


e = fn hex ->
  "0x" <> hex = String.trim(hex)
  {:ok, bin} = Base.decode16(hex, case: :mixed)
  {:binary.at(bin, 194) == 0xFD, Base.encode16(<<:binary.at(bin, 194)>>)}
end

REVERT = FD

# Jul 1st

anvil --fork-url https://moonbeam.unitedbloc.com:3000 -p1454


# June 28th


export CHAINS_MOONBEAM_RPC='!https://moonbeam.api.onfinality.io/?apikey=49e8baf7-14c3-4d0f-916a-94abf1c4c14a'
export CHAINS_MOONBEAM_WS='!wss://moonbeam.api.onfinality.io/ws?apikey=49e8baf7-14c3-4d0f-916a-94abf1c4c14a'

from = Wallet.from_address(Base16.decode("0x7102533B13b950c964efd346Ee15041E3e55413f"))
multisig = Base16.decode("0x3d565Ec28595c1a0710ABCBd8C0F979d31E38704")
Shell.call_from(Chains.Moonbeam, from, multisig, "executeTransaction", ["uint256"],  [9])
{tx, blockRef} = Shell.tx_from(Chains.Moonbeam, from, multisig, "executeTransaction", ["uint256"],  [9])

alias RemoteChain.Transaction

RemoteChain.RPC.rpc(
  Chains.Moonbeam,
  "debug_traceTransaction",
  ["0x63d7cc1b08b18862ae8b277891089ba414ad7959edf5b554f23061afd9a384a5"]
)


"debug_traceCall"

# June 27th

:binary.bin_to_list(f) |> Enum.chunk_every(32)

# June 26th

## Good
{chain, to, from, data, block} = {15, "0x5000000000000000000000000000000000000000",
 "0xae699211c62156b8f29ce17be47d2f069a27f2a6",
 "0x8e0383a40000000000000000000000006000000000000000000000000000000000000000",
 "latest"}

## Bad
{chain, to, from, data, block} = {15, "0x5000000000000000000000000000000000000000",
 "0xae699211c62156b8f29ce17be47d2f069a27f2a6",
 "0x8e0383a40000000000000000000000006000000000000000000000000000000000000000",
 7474380}

method = "eth_call"
params = [%{to: to, data: data, from: from}, block]
request = %{"jsonrpc" => "2.0", "id" => 1_000_000, "method" => method, "params" => params} |> Poison.encode!()

Network.Rpc.execute_rpc(method, Poison.encode!(params) |> Poison.decode!(), [])

export host=localhost:3834
curl -vk -H "Content-Type: application/json" --data "{\"params\":[{\"to\":\"0x5000000000000000000000000000000000000000\",\"from\":\"0xae699211c62156b8f29ce17be47d2f069a27f2a6\",\"data\":\"0x8e0383a40000000000000000000000006000000000000000000000000000000000000000\"},7474380],\"method\":\"eth_call\",\"jsonrpc\":\"2.0\",\"id\":1000000}'" $host

:code.add_patha('/opt/diode_node/')

for mod <- [Shell, RemoteChain.RPC] do
  :code.load_file(mod)
  Process.sleep(1000)
  :code.purge(mod)
end

:code.load_file(Contract.Registry)
:code.purge(Contract.Registry)
chain_id = Chains.Diode.chain_id()
fleet = Chains.DiodeDev.developer_fleet_address()
f = Contract.Registry.call(chain_id, "EpochFleet", ["address"], [fleet], "latest")
f = Contract.Registry.call(chain_id, "EpochFleet", ["address"], [fleet], 7474380)
f = Contract.Registry.call(chain_id, "EpochFleet", ["address"], [fleet], "0x720ccc")
f = Contract.Registry.call(chain_id, "EpochFleet", ["address"], [fleet], "7474380")
[fleet, totalConnections, totalBytes, nodeArray] = ABI.decode_types(["address", "uint256", "uint256", "address[]"], f)
[fleet, totalConnections, totalBytes, nodeArray] = ABI.decode_types(["bytes32", "bytes32", "bytes32", "address[]"], f)

for n <- 1..20 do
  spawn(fn -> Contract.Registry.call(chain_id, "EpochFleet", ["address"], [fleet], 7474380) end)
  Process.sleep(1000)
end

:code.load_file(ABI)
:code.purge(ABI)

# June 25th
:code.add_patha('/opt/diode_node/')
:code.load_file(Network.Rpc)
:code.purge(Network.Rpc)

:code.add_patha('/opt/diode_node/')
:code.load_file(Network.Stats)
:code.purge(Network.Stats)

Network.Rpc.execute_dio("dio_traffic", [15])
Network.Rpc.execute_dio("dio_usageHistory", [System.os_time(:second)- 100, System.os_time(:second), 10]) |> elem(0)
Network.Rpc.execute_dio("dio_usageHistory", [1719311919,1719398319,100])

Network.Stats.get_history(1719311919,1719398319,100) |> map_size()

{"jsonrpc":"2.0","id":9,"method":"dio_usageHistory","params":[1719311919,1719398319,10]}

Network.Stats.get_history(System.os_time(:second)- 100, System.os_time(:second), 10) |> Map.keys()

lru = :persistent_term.get(Network.Stats.LRU)
s = System.os_time(:second) - rem(System.os_time(:second), 10)
DetsPlus.LRU.get(lru, s)


# June 24th

:code.load_file(Network.Rpc)
Network.Rpc.execute_dio("dio_traffic", [15])
Network.Rpc.execute_dio("dio_usage", [])

# June 20th

:code.load_file(Network.Rpc)

conns = Network.Server.get_connections(Network.EdgeV2)

RemoteChain.RPCCache.get_storage(Chains.Diode, "0xaf60faa5cd840b724742f1af116168276112d6a6")
RemoteChain.RPCCache.get_storage(Chains.Diode, "0xaf60faa5cd840b724742f1af116168276112d6a6")

RemoteChain.RPCCache.get_block_by_number(Chains.Diode, 7440835)
RemoteChain.RPC.get_block_by_number(Chains.Diode, 7440835)



pid = :global.whereis_name({RemoteChain.RPCCache, Chains.Diode})
state = :sys.get_state(pid)

Map.get(state.request_rpc, {"eth_getStorage", ["0xaf60faa5cd840b724742f1af116168276112d6a6", "0x71905f"]})

RemoteChain.RPCCache.get_balance(Chains.Diode, "0xdd2fd4581271e230360230f9337d5c0430bf44c0", 7442951)
RemoteChain.RPC.get_balance(Chains.Diode, "0xdd2fd4581271e230360230f9337d5c0430bf44c0", 7442951)
Map.get(:sys.get_state(pid).request_rpc, {"eth_getBalance", ["0xdd2fd4581271e230360230f9337d5c0430bf44c0", "0x719207"]})

:global.whereis_name({RemoteChain.NodeProxy, Chains.Diode})

RemoteChain.RPCCache.rpc(Chains.Diode, "dio_edgev2", ["0xd48f676574626c6f636b68656164657232837192bd"])

# June 6th
addr = "0x853cc395280a389331de3c7ed7c38588c109e762"
owner_slot = Hash.to_address(51) |> Base16.encode()
chain = Chains.Moonbeam
RemoteChain.RPCCache.get_storage_at(chain, addr, owner_slot, 6316617)
RemoteChain.RPCCache.get_storage_at(chain, addr, owner_slot, "latest")

latest = RemoteChain.RPCCache.resolve_block(chain, "latest")
RemoteChain.RPCCache.get_last_change(chain, addr, latest)

# May 15th
CLIENT1: 0xd5ac10782e3b8650f32731ec2a472775d46770a6
CLIENT2: 0x3c8b8039f1615a45f02b640c643481c2b08a8db1
