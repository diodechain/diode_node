# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Contract.Registry do
  @moduledoc """
    Wrapper for the DiodeRegistry contract functions
    as needed by the inner workings of the chain
  """

  def epoch(chain_id, blockRef) do
    call(chain_id, "Epoch", [], [], blockRef)
    |> :binary.decode_unsigned()
  end

  def fleet(chain_id, fleet, block_ref \\ "latest") do
    fleet = call(chain_id, "GetFleet", ["address"], [fleet], block_ref)

    [exists, currentBalance, withdrawRequestSize, withdrawableBalance, currentEpoch, score] =
      ABI.decode_types(["bool", "uint256", "uint256", "uint256", "uint256", "uint256"], fleet)

    %{
      exists: exists,
      currentBalance: currentBalance,
      withdrawRequestSize: withdrawRequestSize,
      withdrawableBalance: withdrawableBalance,
      currentEpoch: currentEpoch,
      score: score
    }
  end

  def relay_rewards(chain_id, address) do
    call(chain_id, "relayRewards", ["address"], [address]) |> :binary.decode_unsigned()
  end

  def current_epoch(chain_id) do
    call(chain_id, "currentEpoch") |> :binary.decode_unsigned()
  end

  def submit_ticket_raw_tx([chain_id | ticket]) do
    Shell.transaction(
      Diode.wallet(),
      RemoteChain.registry_address(chain_id),
      "SubmitTicketRaw",
      ["bytes32[]"],
      [ticket],
      chainId: chain_id
    )
  end

  def call(chain_id, name, types \\ [], values \\ [], blockRef \\ "latest") do
    Shell.call(chain_id, RemoteChain.registry_address(chain_id), name, types, values,
      blockRef: blockRef
    )
    |> Base16.decode()
  end
end
