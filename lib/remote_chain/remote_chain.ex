# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule RemoteChain do
  @moduledoc """
  Wrapper to access RemoteChain details. Usually each method requires the chain_id to be passed as the first argument.
  """

  alias DiodeClient.Base16

  def epoch(chain_id, number \\ nil),
    do: chainimpl(chain_id).epoch(number || peaknumber(chain_id))

  def epoch_progress(chain_id, number), do: chainimpl(chain_id).epoch_progress(number)
  def block(chain_id, number), do: RemoteChain.RPCCache.get_block_by_number(chain_id, number)
  def blockhash(chain_id, number), do: block(chain_id, number)["hash"] |> Base16.decode()
  def blocktime(chain_id, number), do: block(chain_id, number)["timestamp"] |> Base16.decode_int()
  def peaknumber(chain_id), do: RemoteChain.RPCCache.block_number(chain_id)
  def registry_address(chain_id), do: chainimpl(chain_id).registry_address()
  def developer_fleet_address(chain_id), do: chainimpl(chain_id).developer_fleet_address()
  def transaction_hash(chain_id), do: chainimpl(chain_id).transaction_hash()

  if Mix.env() == :test do
    def diode_l1_fallback(), do: Chains.DiodeStaging
    @chains [Chains.DiodeStaging, Chains.Anvil]
  else
    def diode_l1_fallback(), do: Chains.Diode

    @chains [
      Chains.Diode,
      Chains.Moonbeam,
      Chains.OasisSapphire
    ]
  end

  @all_chains Enum.uniq([
                Chains.DiodeDev,
                Chains.DiodeStaging | @chains
              ])

  @doc """
  This function reads endpoints from environment variables when available. So it's possible
  to override the default endpoints by setting the environment variables like `CHAINS_MOONBEAM_WS`.
  """
  def ws_endpoints(chain) do
    String.upcase("#{inspect(chain)}_WS")
    |> String.replace(".", "_")
    |> maybe_override(chain, :ws_endpoints)
  end

  @doc """
  This function reads endpoints from environment variables when available. So it's possible
  to override the default endpoints by setting the environment variables like `CHAINS_MOONBEAM_RPC`.
  """
  def rpc_endpoints(chain) do
    String.upcase("#{inspect(chain)}_RPC")
    |> String.replace(".", "_")
    |> maybe_override(chain, :rpc_endpoints)
  end

  defp maybe_override(name, chain, key) do
    case System.get_env(name) do
      nil -> apply(chainimpl(chain), key, [])
      "!" <> value -> String.split(value)
      "+" <> value -> String.split(value) ++ apply(chainimpl(chain), key, [])
      value -> String.split(value)
    end
  end

  def chains(), do: @chains

  for chain <- @all_chains do
    def chainimpl(unquote(chain.chain_id())), do: unquote(chain)
    def chainimpl(unquote(chain.chain_prefix())), do: unquote(chain)
    def chainimpl(unquote(chain)), do: unquote(chain)
  end

  def chainimpl(module) when is_atom(module), do: module
  def chainimpl(other), do: raise("Unknown chain #{inspect(other)}")
end
