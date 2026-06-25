# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Chains do
  @epoch_block_cache :chains_epoch_block_cache

  def epoch(chain, block_height) do
    div(RemoteChain.blocktime(chain, block_height), chain.epoch_duration())
  end

  def epoch_progress(chain, block_height) do
    rem(RemoteChain.blocktime(chain, block_height), chain.epoch_duration()) /
      chain.epoch_duration()
  end

  @doc """
  Returns the first block whose timestamp is at or after `epoch * epoch_duration()`.

  Uses binary search over real block timestamps instead of extrapolating from a
  fixed block interval. Moonbeam's RT3000 upgrade (block 7_299_818) halved block
  time from 12s to 6s; a single-interval estimate drifts by weeks for older epochs.
  """
  def epoch_block(chain, epoch) when is_atom(chain) do
    ensure_epoch_block_cache()

    DiodeClient.ETSLru.fetch(@epoch_block_cache, {chain, epoch}, fn ->
      epoch_block_uncached(chain, epoch)
    end)
  end

  @doc false
  def first_block_at_or_after_timestamp(blocktime_fun, target, lo, hi)
      when is_function(blocktime_fun, 1) and is_integer(target) and lo <= hi do
    first_block_at_or_after_timestamp_loop(blocktime_fun, target, lo, hi)
  end

  defp first_block_at_or_after_timestamp_loop(blocktime_fun, target, lo, hi) when lo < hi do
    mid = div(lo + hi, 2)

    if blocktime_fun.(mid) < target do
      first_block_at_or_after_timestamp_loop(blocktime_fun, target, mid + 1, hi)
    else
      first_block_at_or_after_timestamp_loop(blocktime_fun, target, lo, mid)
    end
  end

  defp first_block_at_or_after_timestamp_loop(_blocktime_fun, _target, lo, _hi), do: lo

  defp epoch_block_uncached(chain, epoch) do
    target = epoch * chain.epoch_duration()
    peak = RemoteChain.peaknumber(chain)
    peak_ts = RemoteChain.blocktime(chain, peak)

    if target > peak_ts do
      peak
    else
      first_block_at_or_after_timestamp(
        fn n -> RemoteChain.blocktime(chain, n) end,
        target,
        1,
        peak
      )
    end
  end

  defp ensure_epoch_block_cache() do
    if :ets.info(@epoch_block_cache) == :undefined do
      DiodeClient.ETSLru.new(@epoch_block_cache, 512)
    end
  end

  # Approximate inverse of epoch/1; kept for reference and tests.
  def timestamp_block(base_height, base_timestamp, search_timestamp, block_intervall) do
    base_height - floor((base_timestamp - search_timestamp) / block_intervall)
  end

  if Mix.env() == :test do
    def default_ticket_chain(), do: Chains.Anvil
  else
    def default_ticket_chain(), do: Chains.Moonbeam
  end
end

defmodule Chains.Diode do
  alias DiodeClient.{Base16, Hash}

  def chain_id(), do: 15
  def expected_block_intervall(), do: 15
  def epoch(n), do: div(n, 40320)
  def epoch_progress(n), do: rem(n, 40320) / 40320
  def epoch_block(epoch), do: epoch * 40320
  def chain_prefix(), do: "diode"
  def rpc_endpoints(), do: ["https://prenet.diode.io:8443"]
  def ws_endpoints(), do: ["wss://prenet.diode.io:8443/ws"]
  def registry_address(), do: Base16.decode("0x5000000000000000000000000000000000000000")
  def developer_fleet_address(), do: Base16.decode("0x6000000000000000000000000000000000000000")
  def transaction_hash(), do: &Hash.sha3_256/1
end

defmodule Chains.DiodeStaging do
  alias DiodeClient.{Base16, Hash}

  def chain_id(), do: 13
  def expected_block_intervall(), do: 15
  def epoch(n), do: div(n, 40320)
  def epoch_progress(n), do: rem(n, 40320) / 40320
  def epoch_block(epoch), do: epoch * 40320
  def chain_prefix(), do: "diodestg"
  def rpc_endpoints(), do: ["https://staging.diode.io:8443"]
  def ws_endpoints(), do: ["wss://staging.diode.io:8443/ws"]
  def registry_address(), do: Base16.decode("0x5000000000000000000000000000000000000000")
  def developer_fleet_address(), do: Base16.decode("0x6000000000000000000000000000000000000000")
  def transaction_hash(), do: &Hash.sha3_256/1
end

defmodule Chains.DiodeDev do
  alias DiodeClient.{Base16, Hash}

  def chain_id(), do: 5777
  def expected_block_intervall(), do: 15
  def epoch(n), do: div(n, 40320)
  def epoch_progress(n), do: rem(n, 40320) / 40320
  def epoch_block(epoch), do: epoch * 40320
  def chain_prefix(), do: "ddev"
  def rpc_endpoints(), do: ["http://localhost:8443"]
  def ws_endpoints(), do: ["ws://localhost:8443/ws"]
  def registry_address(), do: Base16.decode("0x5000000000000000000000000000000000000000")
  def developer_fleet_address(), do: Base16.decode("0x6000000000000000000000000000000000000000")
  def transaction_hash(), do: &Hash.sha3_256/1
end

defmodule Chains.Moonbeam do
  alias DiodeClient.{Base16, Hash}

  def chain_id(), do: 1284
  def expected_block_intervall(), do: 6
  def epoch(n), do: Chains.epoch(__MODULE__, n)
  def epoch_progress(n), do: Chains.epoch_progress(__MODULE__, n)

  def epoch_block(epoch), do: Chains.epoch_block(__MODULE__, epoch)

  def epoch_duration(), do: 2_592_000
  def chain_prefix(), do: "glmr"

  def additional_endpoints() do
    ~w(
      https://moonbeam.api.onfinality.io/public
      https://moonbeam.unitedbloc.com
      https://1rpc.io/glmr)
  end

  def rpc_endpoints(), do: RemoteChain.ChainList.rpc_endpoints(__MODULE__, additional_endpoints())
  def ws_endpoints(), do: RemoteChain.ChainList.ws_endpoints(__MODULE__, additional_endpoints())
  def registry_address(), do: Base16.decode("0xD78653669fd3df4dF8F3141Ffa53462121d117a4")
  def developer_fleet_address(), do: Base16.decode("0xa0A4dc6623eC96122066195DE34a813846dC0fC0")
  def transaction_hash(), do: &Hash.keccak_256/1

  def check_url(url) do
    # Smoke check for BNS contract check, only for debugging
    RemoteChain.HTTP.rpc(url, "eth_call", [
      %{to: "0x8A093E3A83F63A00FFFC4729AA55482845A49294", data: "0xbb62860d"},
      "latest"
    ])
    |> case do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end
end

defmodule Chains.Moonriver do
  alias DiodeClient.{Base16, Hash}

  def chain_id(), do: 1285
  def expected_block_intervall(), do: 6
  def epoch(n), do: Chains.epoch(__MODULE__, n)
  def epoch_progress(n), do: Chains.epoch_progress(__MODULE__, n)
  def epoch_block(block), do: Chains.epoch_block(__MODULE__, block)
  def epoch_duration(), do: 2_592_000
  def chain_prefix(), do: "movr"

  def additional_endpoints(),
    do:
      ~w(https://moonriver-rpc.dwellir.com https://moonriver.api.onfinality.io/public https://moonriver.unitedbloc.com https://moonriver.public.curie.radiumblock.co/http https://moonriver.rpc.grove.city/v1/01fdb492)

  def rpc_endpoints(), do: RemoteChain.ChainList.rpc_endpoints(__MODULE__, additional_endpoints())
  def ws_endpoints(), do: RemoteChain.ChainList.ws_endpoints(__MODULE__, additional_endpoints())
  def registry_address(), do: Base16.decode("0xEb0aDCd736Ae9341DFb635759C5D7D6c2D51B673")
  def developer_fleet_address(), do: Base16.decode("0x6000000000000000000000000000000000000000")
  def transaction_hash(), do: &Hash.keccak_256/1
end

defmodule Chains.OasisSapphire do
  alias DiodeClient.{Base16, Hash}

  def chain_id(), do: 23294
  def expected_block_intervall(), do: 6
  def epoch(n), do: Chains.epoch(__MODULE__, n)
  def epoch_progress(n), do: Chains.epoch_progress(__MODULE__, n)
  def epoch_block(epoch), do: Chains.epoch_block(__MODULE__, epoch)
  def epoch_duration(), do: 2_592_000
  def chain_prefix(), do: "sapphire"
  def rpc_endpoints(), do: RemoteChain.ChainList.rpc_endpoints(__MODULE__)
  def ws_endpoints(), do: RemoteChain.ChainList.ws_endpoints(__MODULE__)
  def registry_address(), do: raise("not implemented")
  def developer_fleet_address(), do: raise("not implemented")
  def transaction_hash(), do: &Hash.keccak_256/1
end
