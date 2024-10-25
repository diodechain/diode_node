defmodule CallPermitAdapter do
  alias DiodeClient.{Base16}

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
end
