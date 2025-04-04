defmodule CallPermitAdapter do
  alias DiodeClient.{Base16, Rlp}

  # 0xe7f13b866a7fc159cb6ee32bcb4103cf0477652e
  def wallet() do
    Diode.wallet()
  end

  def rpc_call!(chain, call, from \\ nil, blockref \\ "latest") do
    {:ok, ret} = rpc_call(chain, call, from, blockref)
    ret
  end

  def rpc_call(chain, call, from \\ nil, blockref \\ "latest") do
    from = if from != nil, do: Base16.encode(from)

    RemoteChain.RPC.call(
      chain,
      Base16.encode(DiodeClient.Contracts.CallPermit.address()),
      from,
      Base16.encode(call),
      blockref
    )
  end

  def should_forward_metatransaction?(chain) do
    chain in [Chains.Moonbeam, Chains.Moonriver, Chains.MoonbeamTestnet] and
      Shell.get_balance(chain, Diode.address()) / Shell.ether(1) < 1
  end

  # RLP encoded MetaTransaction
  def forward_metatransaction(chain, meta_transaction) when is_binary(meta_transaction) do
    msg =
      Rlp.encode!([chain.chain_prefix() <> ":sendmetatransaction", meta_transaction])
      |> Base16.encode()

    RemoteChain.RPCCache.rpc!(RemoteChain.diode_l1_fallback(), "dio_edgev2", [msg])
    |> Base16.decode()
    |> Rlp.decode!()
  end
end
