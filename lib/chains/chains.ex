# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Chains do
  def epoch(chain, block_height) do
    div(RemoteChain.blocktime(chain, block_height), chain.epoch_duration())
  end

  def epoch_progress(chain, block_height) do
    rem(RemoteChain.blocktime(chain, block_height), chain.epoch_duration()) /
      chain.epoch_duration()
  end

  def epoch_block(chain, epoch) do
    # last block with 12s: 6593037 Jul-15-2024 01:01:12 PM +UTC => 1721048472
    base_height = RemoteChain.peaknumber(chain)
    base_timestamp = RemoteChain.blocktime(chain, base_height)
    epoch_time = epoch * chain.epoch_duration()

    timestamp_block(base_height, base_timestamp, epoch_time, chain.expected_block_intervall())
  end

  def timestamp_block(base_height, base_timestamp, search_timestamp, block_intervall) do
    base_height - floor((base_timestamp - search_timestamp) / block_intervall)
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

  def epoch_block(epoch) do
    epoch_time = epoch * epoch_duration()
    # last block with 12s: 6593037 Jul-15-2024 01:01:12 PM +UTC => 1721048472
    # after that all blocks have 6s
    expected_block_intervall = if epoch_time > 1_721_048_472, do: 12, else: 6
    Chains.timestamp_block(6_593_037, 1_721_048_472, epoch_time, expected_block_intervall)
  end

  def epoch_duration(), do: 2_592_000
  def chain_prefix(), do: "glmr"

  def additional_endpoints() do
    ~w(
      https://moonbeam.api.onfinality.io/public
      https://moonbeam.unitedbloc.com
      https://moonbeam.public.curie.radiumblock.co/http
      https://1rpc.io/glmr)
  end

  def rpc_endpoints(), do: RemoteChain.ChainList.rpc_endpoints(__MODULE__, additional_endpoints())
  def ws_endpoints(), do: RemoteChain.ChainList.ws_endpoints(__MODULE__, additional_endpoints())
  def registry_address(), do: Base16.decode("0xD78653669fd3df4dF8F3141Ffa53462121d117a4")
  def developer_fleet_address(), do: Base16.decode("0xa0A4dc6623eC96122066195DE34a813846dC0fC0")
  def transaction_hash(), do: &Hash.keccak_256/1
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
