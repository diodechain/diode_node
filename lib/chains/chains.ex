# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Chains.Diode do
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
  def chain_id(), do: 1284
  def expected_block_intervall(), do: 15
  def epoch(n), do: div(RemoteChain.blocktime(__MODULE__, n), epoch_length())

  def epoch_progress(n),
    do: rem(RemoteChain.blocktime(__MODULE__, n), epoch_length()) / epoch_length()

  def epoch_block(epoch), do: epoch_block(epoch, __MODULE__)

  def epoch_block(epoch, chain) do
    n = RemoteChain.peaknumber(chain)
    n_time = RemoteChain.blocktime(chain, n)
    n_epoch = div(n_time, epoch_length())
    block_number = n - (epoch - n_epoch) * epoch_length() / expected_block_intervall()
    floor(block_number)
  end

  def epoch_length(), do: 2_592_000
  def chain_prefix(), do: "glmr"

  def rpc_endpoints(),
    do: [
      "https://moonbeam.unitedbloc.com:3000",
      "https://moonbeam-rpc.publicnode.com",
      "https://rpc.api.moonbeam.network",
      "https://moonbeam-rpc.dwellir.com",
      "https://rpc.ankr.com/moonbeam",
      "https://moonbeam.public.blastapi.io",
      "https://endpoints.omniatech.io/v1/moonbeam/mainnet/public",
      "https://moonbeam.api.onfinality.io/public",
      "https://1rpc.io/glmr"
    ]

  def ws_endpoints(),
    do: [
      "wss://moonbeam.unitedbloc.com:3001",
      "wss://moonbeam-rpc.dwellir.com",
      "wss://wss.api.moonbeam.network",
      "wss://moonbeam-rpc.publicnode.com",
      "wss://moonbeam.api.onfinality.io/public-ws"
    ]

  def registry_address(), do: Base16.decode("0xD78653669fd3df4dF8F3141Ffa53462121d117a4")
  def developer_fleet_address(), do: Base16.decode("0xa0A4dc6623eC96122066195DE34a813846dC0fC0")
  def transaction_hash(), do: &Hash.keccak_256/1
end

defmodule Chains.MoonbaseAlpha do
  def chain_id(), do: 1287
  def expected_block_intervall(), do: 15
  defdelegate epoch(n), to: Chains.Moonbeam
  defdelegate epoch_progress(n), to: Chains.Moonbeam
  def epoch_block(block), do: Chains.Moonbeam.epoch_block(block, Chains.MoonbaseAlpha)
  def epoch_length(), do: 2_592_000
  def chain_prefix(), do: "m1"

  def rpc_endpoints(),
    do: [
      "https://moonbase.unitedbloc.com:1000",
      "https://rpc.testnet.moonbeam.network",
      "https://rpc.api.moonbase.moonbeam.network",
      "https://moonbase-alpha.public.blastapi.io",
      "https://moonbeam-alpha.api.onfinality.io/public"
    ]

  def ws_endpoints(),
    do: [
      "wss://moonbase.unitedbloc.com:1001",
      "wss://wss.api.moonbase.moonbeam.network",
      "wss://moonbeam-alpha.api.onfinality.io/public-ws"
    ]

  def registry_address(), do: Base16.decode("0xEb0aDCd736Ae9341DFb635759C5D7D6c2D51B673")
  def developer_fleet_address(), do: Base16.decode("0x6000000000000000000000000000000000000000")
  def transaction_hash(), do: &Hash.keccak_256/1
end

defmodule Chains.Moonriver do
  def chain_id(), do: 1285
  def expected_block_intervall(), do: 15
  defdelegate epoch(n), to: Chains.Moonbeam
  defdelegate epoch_progress(n), to: Chains.Moonbeam
  def epoch_block(block), do: Chains.Moonbeam.epoch_block(block, Chains.MoonbaseAlpha)
  def epoch_length(), do: 2_592_000
  def chain_prefix(), do: "movr"

  def rpc_endpoints(),
    do: [
      "https://moonriver-rpc.dwellir.com",
      "https://moonriver-rpc.publicnode.com",
      "https://moonriver.api.onfinality.io/public",
      "https://moonriver.drpc.org",
      "https://moonriver.public.blastapi.io",
      "https://moonriver.unitedbloc.com:2000",
      "https://rpc.api.moonriver.moonbeam.network"
    ]

  def ws_endpoints(),
    do: [
      "wss://moonriver-rpc.dwellir.com",
      "wss://moonriver-rpc.publicnode.com",
      "wss://moonriver.api.onfinality.io/public-ws",
      "wss://moonriver.drpc.org",
      "wss://moonriver.unitedbloc.com:2001",
      "wss://wss.api.moonriver.moonbeam.network"
    ]

  def registry_address(), do: Base16.decode("0xEb0aDCd736Ae9341DFb635759C5D7D6c2D51B673")
  def developer_fleet_address(), do: Base16.decode("0x6000000000000000000000000000000000000000")
  def transaction_hash(), do: &Hash.keccak_256/1
end
