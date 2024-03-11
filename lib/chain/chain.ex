defmodule Chain do
  @moduledoc """
  Wrapper to access Chain details. Usually each method requires the chain_id to be passed as the first argument.
  """

  def epoch(_chain_id), do: :todo
  def blockhash(_chain_id, _number), do: :todo
  def blocktime(_chain_id, _number), do: :todo
  def peaknumber(_chain_id), do: :todo
end
