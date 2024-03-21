defmodule Chain do
  @moduledoc """
  Wrapper to access Chain details. Usually each method requires the chain_id to be passed as the first argument.
  """

  def epoch(chain_id, number \\ nil),
    do: chainimpl(chain_id).epoch(number || peaknumber(chain_id))

  def epoch_progress(chain_id, number), do: chainimpl(chain_id).epoch_progress(number)
  def block(chain_id, number), do: Chain.RPCCache.get_block_by_number(chain_id, number)
  def blockhash(chain_id, number), do: block(chain_id, number)["hash"] |> Base16.decode()
  def blocktime(chain_id, number), do: block(chain_id, number)["timestamp"] |> Base16.decode_int()
  def peaknumber(chain_id), do: Chain.RPCCache.block_number(chain_id)
  def registry_address(chain_id), do: chainimpl(chain_id).registry_address()

  @chains [
    Chains.DiodeStaging,
    Chains.Diode,
    Chains.Moonbeam,
    Chains.MoonbaseAlpha
  ]
  def chains(), do: @chains

  for chain <- @chains do
    def chainimpl(unquote(chain.chain_id())), do: unquote(chain)
    def chainimpl(unquote(chain.chain_prefix())), do: unquote(chain)
    def chainimpl(unquote(chain)), do: unquote(chain)
  end

  def chainimpl(_), do: nil
end