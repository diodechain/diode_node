defmodule Chains.Diode do
  def chain_id(), do: 15
  def expected_block_intervall(), do: 15
  def epoch(n), do: div(n, 40320)
  def epoch_progress(n), do: rem(n, 40320) / 40320
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

  def registry_address(), do: Base16.decode("0x5000000000000000000000000000000000000000")
  def developer_fleet_address(), do: Base16.decode("0x6000000000000000000000000000000000000000")
  def transaction_hash(), do: &Hash.keccak_256/1
end

defmodule Chains.MoonbaseAlpha do
  def chain_id(), do: 1287
  def expected_block_intervall(), do: 15
  def epoch(n), do: div(RemoteChain.blocktime(__MODULE__, n), epoch_length())

  def epoch_progress(n),
    do: rem(RemoteChain.blocktime(__MODULE__, n), epoch_length()) / epoch_length()

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
  def epoch(n), do: div(RemoteChain.blocktime(__MODULE__, n), epoch_length())

  def epoch_progress(n),
    do: rem(RemoteChain.blocktime(__MODULE__, n), epoch_length()) / epoch_length()

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

defmodule Chains.Anvil do
  def chain_id(), do: 31337
  def expected_block_intervall(), do: 15
  def epoch(n), do: div(RemoteChain.blocktime(__MODULE__, n), epoch_length())

  def epoch_progress(n),
    do: rem(RemoteChain.blocktime(__MODULE__, n), epoch_length()) / epoch_length()

  def epoch_length(), do: 2_592_000
  def chain_prefix(), do: "av"

  def rpc_endpoints(),
    do: ["http://localhost:8545"]

  def ws_endpoints(),
    do: ["ws://localhost:8545"]

  def registry_address(),
    do:
      ensure_contract("DiodeRegistryLight", [
        foundation_address() |> Base16.encode(),
        diode_token_address() |> Base16.encode()
      ])

  def developer_fleet_address(),
    do:
      ensure_contract("DevFleetContract", [foundation_address() |> Base16.encode()], fn address ->
        Shell.transaction(
          Diode.wallet(),
          diode_token_address(),
          "mint",
          ["address", "uint256"],
          [
            Diode.address(),
            100_000_000_000_000_000
          ],
          chainId: chain_id()
        )
        |> Shell.await_tx()

        Shell.transaction(
          Diode.wallet(),
          diode_token_address(),
          "approve",
          ["address", "uint256"],
          [registry_address(), 100_000_000_000_000_000],
          chainId: chain_id()
        )
        |> Shell.await_tx()

        Shell.transaction(
          Diode.wallet(),
          registry_address(),
          "ContractStake",
          ["address", "uint256"],
          [address, 100_000_000_000_000_000],
          chainId: chain_id()
        )
        |> Shell.await_tx()
      end)

  def bridge_address(), do: wallet_address()
  def foundation_address(), do: wallet_address()

  def diode_token_address(),
    do:
      ensure_contract("DiodeToken", [
        foundation_address() |> Base16.encode(),
        bridge_address() |> Base16.encode(),
        "true"
      ])

  def wallet_address() do
    System.get_env("WALLETS")
    |> String.split(" ")
    |> hd()
    |> Base16.decode()
    |> Wallet.from_privkey()
    |> Wallet.address!()
  end

  def ensure_contract(name, args, postfun \\ nil) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      nil ->
        key = System.get_env("WALLETS") |> String.split(" ") |> hd()

        {text, 0} =
          System.cmd(
            "forge",
            [
              "create",
              "--rpc-url",
              "http://localhost:8545",
              "--private-key",
              key,
              "test/contract_src/#{name}.sol:#{name}",
              "--constructor-args" | args
            ],
            stderr_to_stdout: true
          )

        [_, address] = Regex.run(~r/Deployed to: (0x.{40})/, text)
        address = Base16.decode(address)
        :persistent_term.put({__MODULE__, name}, address)
        if postfun != nil, do: postfun.(address)
        address

      value ->
        value
    end
  end

  def transaction_hash(), do: &Hash.keccak_256/1
end
