defmodule Chain do
  @moduledoc """
  Wrapper to access Chain details. Usually each method requires the chain_id to be passed as the first argument.
  """

  def epoch(_chain_id), do: :todo
  def blockhash(_chain_id, _number), do: :todo
  def blocktime(_chain_id, _number), do: :todo
  def peaknumber(_chain_id), do: :todo
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
  end

  def chainimpl(_), do: nil
end
