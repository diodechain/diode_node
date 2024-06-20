# June 20th

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
