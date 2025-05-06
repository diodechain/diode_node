defmodule CallPermitAdapter do
  alias DiodeClient.{Base16, Rlp}

  def should_forward_metatransaction?(chain) do
    chain not in [Chains.Diode, Chains.DiodeStaging, Chains.DiodeDev] and
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
