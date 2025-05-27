# May 27th
KademliaLight.find_nodes(<<1>>)

# May 27th
key = Diode.hash(<<100>>)
nodes = KademliaLight.find_node_lookup(key)

{:ok, pid} = GenServer.start_link(KademliaSearch, KademliaLight)
spawn(fn -> Profiler.fprof(pid) end)
GenServer.call(pid, {:find_nodes, key, nodes, KBuckets.k(), Network.PeerHandlerV2.find_node()}, 20_000)



# May 20th
key = Diode.hash(<<1>>)
IO.puts(DiodeClient.Base16.encode(key))
KademliaLight.nearest_n(Diode.hash(<<1>>)) |> Enum.take(1) |> Enum.map(fn n ->
  {DiodeClient.Wallet.printable(n.node_id), DiodeClient.Base16.encode(Diode.hash(DiodeClient.Wallet.address!(n.node_id)), false)}
end)
nodes = KademliaLight.nearest_n(Diode.hash(<<1>>)) |> Enum.take(1)
n = hd(nodes)

ret = KademliaSearch.find_nodes(KademliaLight, key, nodes, KBuckets.k(), Network.PeerHandlerV2.find_node())

KademliaLight.rpc(n, [Network.PeerHandlerV2.find_node(), key])

Enum.map(ret, fn n ->
  {DiodeClient.Wallet.printable(n.node_id), DiodeClient.Base16.encode(Diode.hash(DiodeClient.Wallet.address!(n.node_id)), false)}
end)

Enum.map(resp, fn n ->
  {DiodeClient.Wallet.printable(n.node_id), DiodeClient.Base16.encode(Diode.hash(DiodeClient.Wallet.address!(n.node_id)), false)}
end)

# Local info
Diode.address() |> Diode.hash() |> DiodeClient.Base16.encode()
KademliaLight.network() |> KBuckets.to_list() |> Enum.map(fn n ->
  IO.puts(DiodeClient.Base16.encode(Diode.hash(DiodeClient.Wallet.address!(n.node_id))))
end)

# May 19th

0xdca3f52a3aecce20326d5422532f05e1f31408dd drzarkov.glmr
0x1a2323d9 AddMember(address)
tx = "0xae300056ccb8e08c33f7be418349184ea879dd228f3989aeff4afad69b73e8aa"

[0x11fc4bd8b65c27e8985c700cec0309131cfdc316]
[0x21d2f92d6dc2d886086dbc1b54065335f5af9a97]
[0x32e871b1f7124ba43889551d3eff4f636b25ecf2]
[0x51910aa1cbd5eb924b380715c6027b0de2a1e4ec]
[0x623299542c4afe8cd39da33f80bf698d57d9cb5c]
[0x6dc6862089d3332061dfd0c8914e1858d62085c2]
[0xbb66b66dbf7b290f927d3253e5dc53667dd84656]
[0xe274554c679081f46bdd6f6f639a85e8f3ab42b5]

# May 14th

cache = GenServer.call({:global, {RemoteChain.RPCCache, Chains.Diode}}, :cache)

# May 7th

call = DiodeClient.ABI.encode_call("__proxy_set_target", ["address"], [0x44F5BE42c3943e37e05012616A278466cbB03565]) |> DiodeClient.Base16.encode()
"0x7841980f00000000000000000000000044f5be42c3943e37e05012616a278466cbb03565"

export RPC=https://sapphire.oasis.io
cast send --legacy --rpc-url $RPC --private-key $(cat diode_glmr.key) 0xDA92764BB12E91010D132BcDd8e4a0270EE25fc9 "submitTransaction(address destination, uint256 value, bytes memory data)" 0xBC7a66a80E760dD0D84f6e39Df6cfD937C6c94F6 0 0x7841980f00000000000000000000000044f5be42c3943e37e05012616a278466cbb03565

# April 7th

# Debugging updater issues

gateway = DiodeClient.Base16.decode("0x84c485c62cdd878ce795aa90f269f84b5ae4fa0e")
updater = DiodeClient.Base16.decode("0x35480f4de422827d4fd80c47a5cf5f2f4622f2aa")

updater_pid = Network.Server.get_connections(Network.EdgeV2)[updater]
gateway_pid = Network.Server.get_connections(Network.EdgeV2)[gateway]
:sys.get_state(updater_pid)
:sys.get_state(gateway_pid)

ports = :sys.get_state(updater_pid).ports.pid
:sys.get_state(ports)

# Feb 5th

anvil --steps-tracing --fork-url https://moonbeam.unitedbloc.com:3000 -p1454
url = "http://localhost:1454"
tx_hash = "0x792e480e00e4938a5916be01370f4ff36b342eaa41a1ccd27a7aa7a4aead3593"
tx_hash = "0xb41c37d767f71f66149d34324611869cb6315d18fc775241244efabb913f93e9"
{:ok, trace} = RemoteChain.HTTP.rpc(url, "debug_traceTransaction", [tx_hash, %{tracer: "callTracer"}])

url = "https://moonbeam.api.onfinality.io/rpc?apikey=49e8baf7-14c3-4d0f-916a-94abf1c4c14a"
{:ok, trace} = RemoteChain.HTTP.rpc(url, "debug_traceTransaction", [tx_hash])


# Jan 13th

tx = "0x9a59b0b9f2dfdcd71af946e607e3f6ea0ccf9a382b89e3806066d91b4b2b406b"
Shell.trace_moon_tx(tx)
# Jan 3rd

n = <<162, 250, 108, 124, 66, 239, 216, 146, 43, 20, 78, 139, 210, 11, 137, 154, 234, 206, 70, 152>>
node_id = {:wallet, nil,
   <<3, 253, 245, 150, 223, 41, 186, 110, 251, 230, 65, 137, 248, 79, 181, 87,
     173, 238, 56, 121, 216, 68, 174, 50, 154, 221, 174, 252, 211, 56, 0, 227,
     138>>,
   <<162, 250, 108, 124, 66, 239, 216, 146, 43, 20, 78, 139, 210, 11, 137, 154,
     234, 206, 70, 152>>}
port = 51055
address = "38.148.120.19"
pid = Network.Server.ensure_node_connection(Network.PeerHandlerV2, node_id, address, port)
pid = Network.Server.ensure_node_connection(Network.PeerHandlerV2, nil, address, port)

# Jan 1st

anvil --steps-tracing --fork-url https://moonbeam.unitedbloc.com:3000 -p1454
url = "http://localhost:1454"
tx_hash = "0x46b73ab082974503b7c8130caba521855e43b77e2f4ee83f36fcca6f34c13ae0"
{:ok, trace} = RemoteChain.HTTP.rpc(url, "debug_traceTransaction", [tx_hash, %{tracer: "callTracer"}])

url = "https://moonbeam.api.onfinality.io/rpc?apikey=49e8baf7-14c3-4d0f-916a-94abf1c4c14a"
{:ok, trace} = RemoteChain.HTTP.rpc(url, "debug_traceTransaction", [tx_hash])

# Nov 8th

letz = "0x0530f2dfdab4860f4c0bde8a7bced46b1b76038d"


node_id = "0x39905d59e9de79912e2545bc1751dbb900249493"
node = DiodeClient.Base16.decode(node_id)
Network.Rpc.execute_dio("dio_network", []) |> elem(0) |> elem(1) |> Enum.filter(fn n -> n.node_id == node_id end)

Model.KademliaSql.object(Diode.hash(node)) |> DiodeClient.Object.decode!()


Network.Rpc.execute_dio("dio_network", [])

# Nov 6th
Network.Rpc.execute_dio("dio_traffic", [Chains.Moonbeam.chain_id()])


chain_id = Chains.Moonbeam.chain_id()
blocknum = RemoteChain.peaknumber(chain_id)
RemoteChain.epoch_progress(chain_id, blocknum)

epoch = RemoteChain.epoch(chain_id, blocknum)
tickets = TicketStore.tickets(chain_id, epoch - 1)

best = tickets |> Enum.sort_by(&TicketStore.estimate_ticket_value/1, :desc) |> Stream.filter(fn tck -> TicketStore.validate_ticket(tck) == :ok end) |> Enum.take(10)




# Oct 24th

chain_id = Chains.Moonbeam.chain_id()
blocknum = RemoteChain.peaknumber(chain_id)
RemoteChain.epoch_progress(chain_id, blocknum)

epoch = RemoteChain.epoch(chain_id, blocknum)
TicketStore.tickets(chain_id, epoch - 1)



TicketStore.submit_tickets(chain_id, epoch - 1)


# Oct 22nd

chain_id = Chains.Moonbeam.chain_id()
blocknum = RemoteChain.peaknumber(chain_id)
RemoteChain.epoch_progress(chain_id, blocknum)

epoch = RemoteChain.epoch(chain_id, blocknum)
TicketStore.submit_tickets(chain_id, epoch - 1)

# Oct  18th

anvil --steps-tracing --fork-url https://moonbeam.unitedbloc.com:3000 -p1454
url = "http://localhost:1454"
tx_hash = "0x35df975d150e0c3bed459909ae4deb924b88de2cc441aa894f5fef08ee08af66"
{:ok, trace} = RemoteChain.HTTP.rpc(url, "debug_traceTransaction", [tx_hash, %{tracer: "callTracer"}])


# Sep 26th

{:global, name} = RemoteChain.NodeProxy.name(Chains.Moonbeam)
pid = :global.whereis_name(name)
state = :sys.get_state(pid)

:sys.get_state(pid).requests

sample = fn ->
  :sys.get_state(pid).requests |> Enum.map(fn {_, req} ->
    {req.method, req.params}
  end)
end


0x1e4717b2dc5dfd7f487f2043bfe9999372d693bf4d9c51b5b84f1377939cd487

0x42a7b7dd785cd69714a189dffb3fd7d7174edc9ece837694ce50f7078f7c31ae

# Sep 24th

Recover ids can be changed cuasing Ticket.device_address(tck) to crash

# Sep 23rd

Network.Rpc.execute_dio("dio_network", [])
Network.Rpc.execute_dio("dio_usageHistory", [1727072000, 1727100800, 300])
Network.Rpc.execute_dio("dio_proxy|dio_usageHistory", ["0x7e4cd38d266902444dc9c8f7c0aa716a32497d0b", 1727072000, 1727100800, 300])
Network.Rpc.execute_dio("dio_checkConnectivity", [])
Network.Rpc.execute_dio("dio_checkConnectivity", [])
Connectivity.query_connectivity()

{"jsonrpc":"2.0","id":3,"method":"dio_proxy|dio_usageHistory","params":["0x090ad02cebd8fbbe0b411f5d870ab69d1004d6d8"]}
{"jsonrpc":"2.0","id":3,"method":"dio_proxy|dio_connectivity","params":["0x090ad02cebd8fbbe0b411f5d870ab69d1004d6d8"]}
{"jsonrpc":"2.0","id":3,"method":"dio_proxy|dio_connectivity","params":["0xce0b425bf2f2e7c26b4c2401435c655f8f446052"]}

HTTPoison.post("http://eu2.prenet.diode.io:8545", ~S({"jsonrpc":"2.0","id":3,"method":"dio_proxy|dio_usageHistory","params":["0x090ad02cebd8fbbe0b411f5d870ab69d1004d6d8", 1727072000, 1727100800, 300]}), [
  {"Content-Type", "application/json"},
  {"Accept-Encoding", "gzip"}
])

# Sep 11th

from = "0xdD1970aFe4D76038D5f0F4a44d9Cb435450c623a"
to = "0x8a093e3A83F63A00FFFC4729aa55482845a49294"
data = "0x3e49fb7e00000000000000000000000000000000000000000000000000000000000000400000000000000000000000006a91521d1adc31ca434cb5346d9d95ce4b244a68000000000000000000000000000000000000000000000000000000000000000f64696f6465746573742d68723231350000000000000000000000000000000000"
method = "eth_call"
params = [%{to: to, data: data, from: from}, 7408732]
{:ok, tx} = RemoteChain.HTTP.rpc(url, method, params)



anvil --fork-url https://moonbeam.unitedbloc.com:3000 -p1454

url = "https://moonbeam.api.onfinality.io/rpc?apikey=49e8baf7-14c3-4d0f-916a-94abf1c4c14a"
url = "https://moonbeam.unitedbloc.com:3000"
url = "http://localhost:1454"
tx_hash = "0x3db297eb5ea034a01ff795de5ab4b0bcc4ef582a952d8840abc8036ccc093d39"
{:ok, trace} = RemoteChain.HTTP.rpc(url, "debug_traceTransaction", [tx_hash])


{:ok, tx} = RemoteChain.HTTP.rpc(url, "eth_getTransactionByHash", [tx_hash])



# Sep 9th

ddriveupdate = <<53, 72, 15, 77, 228, 34, 130, 125, 79, 216, 12, 71, 165, 207, 95, 47, 70, 34, 242, 170>>
KademliaLight.find_value(ddriveupdate) |> Object.decode!()

KademliaLight.find_value(key) |> Object.decode!()

key = KademliaLight.hash(ddriveupdate)
Model.KademliaSql.object(key) |> Object.decode!()

us2 = Base16.decode("0x7e4cd38d266902444dc9c8f7c0aa716a32497d0b")
as1 = Base16.decode("0x68e0bafdda9ef323f692fc080d612718c941d120")

KademliaLight.find_value(us2)
KademliaLight.find_node(us2)
KademliaLight.find_node(as1)


# Aug 17th

now = System.os_time(:second)
KademliaLight.network() |> KBuckets.to_list() |> Enum.reject(fn n -> KBuckets.is_self(n) or n.last_connected == nil end) |> Enum.reject(fn n -> now - n.last_connected < 60*30 end) |> length()
network |> KBuckets.to_list() |> Enum.reject(fn n -> KBuckets.is_self(n) end) |> Enum.reject(fn n -> now - n.last_connected < 60*30 end) |> length()

network = KademliaLight.network()
deadline = System.os_time(:second) - 60 * 30
stale = KBuckets.to_list(network) |> Enum.reject(fn n -> KBuckets.is_self(n) end) |> Enum.reject(fn n -> n.last_connected > deadline end)
network = Enum.reduce(stale, network, fn stale_node, network -> KBuckets.delete_item(network, stale_node) end)


# Aug 1st

node = Base16.decode("0x625dc9fb40390992c15f146a8b18850b27b663d6") |> Wallet.from_address()
nodes = KademliaLight.network() |> KBuckets.to_list()

Enum.find(nodes, fn n -> Wallet.equal?(n.node_id, node) end)

Model.KademliaSql.object("ABC") |> Object.decode!()

# Jul 11th

token = "0x434116a99619f2B465A137199C38c1Aab0353913" |> Base16.decode()
Shell.call(Chains.Moonbeam.chain_id(), token, "name")
Shell.call(Chains.Moonbeam.chain_id(), token, "decimals")

# Jul 10th
chain_id = Chains.Moonbeam.chain_id()
epoch = RemoteChain.epoch(chain_id)
fleet_addr = "0x8afe08d333f785c818199a5bdc7a52ac6ffc492a" |> Base16.decode()
TicketStore.fleet_value(chain_id, fleet_addr, 662)

TicketStore.estimate_ticket_value(tck)
TicketStore.fleet_value(chain_id, Ticket.fleet_contract(tck), Ticket.epoch(tck))
Network.Rpc.execute_dio("dio_traffic", [Chains.Moonbeam.chain_id()])

# Jul 9th
:code.add_patha('/opt/diode_node/')
for mod <- [TicketStore, Shell] do
  :code.load_file(mod)
  Process.sleep(1000)
  :code.purge(mod)
end

"0xeaf4de5f51daf557643b85637778cfa0e40013eb063ea0d739f5b7e736fde9d8"

chain_id = Chains.Moonbeam.chain_id()
epoch = RemoteChain.epoch(chain_id)
block = RemoteChain.chainimpl(chain_id).epoch_block(epoch)

blocknum = RemoteChain.peaknumber(chain_id)
RemoteChain.epoch_progress(chain_id, blocknum)

TicketStore.newblock(chain_id, blocknum)
TicketStore.submit_tickets(chain_id, epoch)


[tck | rest] = TicketStore.tickets(chain_id, epoch - 1)
tx = Ticket.raw(tck) |> Contract.Registry.submit_ticket_raw_tx(chain_id)


Shell.submit_tx(tx)
url = "https://moonbeam.api.onfinality.io/rpc?apikey=49e8baf7-14c3-4d0f-916a-94abf1c4c14a"
Shell.call_tx(tx, "latest")
Shell.debug_tx(tx, url, "latest")
Shell.debug_tx(tx, "127.0.0.1:1545", "latest")

tx_hash = "0xeaf4de5f51daf557643b85637778cfa0e40013eb063ea0d739f5b7e736fde9d8"
{:ok, trace} = RemoteChain.HTTP.rpc(url, "debug_traceTransaction", [tx_hash])

trace["structLogs"] |> Enum.map(fn %{"op" => op, "pc" => pc} -> IO.puts("#{pc} #{op}") end)

rpc(chain, "debug_traceCall", [%{to: to, data: data, from: from}, block])

alias Object.Ticket

# DevFleet: https://moonscan.io/address/0x8afe08d333f785c818199a5bdc7a52ac6ffc492a#readProxyContract
fleet_addr = "0x8afe08d333f785c818199a5bdc7a52ac6ffc492a" |> Base16.decode()
Contract.Registry.fleet(chain_id, fleet_addr, Base16.encode(block, false))
Contract.Registry.fleet(chain_id, fleet_addr, Base16.encode(block - 100, false))

Network.Rpc.execute_dio("dio_traffic", [Chains.Moonbeam.chain_id()])


fleet_obj = Contract.Registry.call(chain_id, "GetFleet", ["address"], [fleet_addr], Base16.encode(block, false))

# Jul 9th

handle = GenServer.call(:remoterpc_cache, :get_handle)
DetsPlus.delete_all_objects(:remoterpc_cache)
Enum.take(handle, 50_000) |> Enum.map(fn e -> elem(e, 0) end) |> Enum.filter(&is_integer/1) |> Enum.min_max()
handle |> Enum.map(fn e -> elem(e, 0) end) |> Enum.filter(&is_integer/1) |> Enum.min_max()


Enum.take(handle, 50_000) |> Enum.reject(fn e -> is_number(elem(e, 0)) end) |> Enum.map(fn {{:key, _key}, _value, n} -> n end) |> Enum.min_max()

Enum.take(handle, 150_000) |> Enum.reduce({0, 0, 0}, fn element, {keys, values, others} ->
  case element do
    {key, _value} when is_integer(key) -> {keys + 1, values, others}
    {{:key, _key}, _value, _n} -> {keys, values + 1, others}
    _ -> {keys, values, others + 1}
  end
end)

Enum.count(handle)


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

alias DiodeClient.Transaction

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
