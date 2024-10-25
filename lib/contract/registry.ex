# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Contract.Registry do
  @moduledoc """
    Wrapper for the DiodeRegistry contract functions
    as needed by the inner workings of the chain
  """
  alias DiodeClient.{ABI, Base16}

  def epoch(chain_id, blockRef) do
    call(chain_id, "Epoch", [], [], blockRef)
    |> :binary.decode_unsigned()
  end

  def fleet(chain_id, fleet, block_ref \\ "latest")

  def fleet(chain_id, fleet, block_ref) do
    if RemoteChain.chainimpl(chain_id) in [Chains.Diode, Chains.DiodeStaging, Chains.DiodeDev] do
      fleet = call(chain_id, "EpochFleet", ["address"], [fleet], block_ref)

      [[_fleet, totalConnections, totalBytes, nodeArray]] =
        ABI.decode_types(["(address, uint256, uint256, address[])"], fleet)

      %{
        totalConnections: totalConnections,
        totalBytes: totalBytes,
        nodeArray: nodeArray
      }
    else
      fleet = call(chain_id, "GetFleet", ["address"], [fleet], block_ref)

      [[exists, currentBalance, withdrawRequestSize, withdrawableBalance, currentEpoch, score]] =
        ABI.decode_types(["(bool, uint256, uint256, uint256, uint256, uint256)"], fleet)

      %{
        exists: exists,
        currentBalance: currentBalance,
        withdrawRequestSize: withdrawRequestSize,
        withdrawableBalance: withdrawableBalance,
        currentEpoch: currentEpoch,
        score: score
      }
    end
  end

  def client_score(chain_id, fleet, node, client, block_ref) do
    if RemoteChain.chainimpl(chain_id) in [Chains.Diode, Chains.DiodeStaging, Chains.DiodeDev] do
      nil
    else
      score =
        call(
          chain_id,
          "GetClientScore",
          ["address", "address", "address"],
          [fleet, node, client],
          block_ref
        )

      hd(ABI.decode_types(["uint256"], score))
    end
  end

  def relay_rewards(chain_id, address) do
    call(chain_id, "relayRewards", ["address"], [address]) |> :binary.decode_unsigned()
  end

  def current_epoch(chain_id) do
    call(chain_id, "currentEpoch") |> :binary.decode_unsigned()
  end

  def submit_ticket_raw_tx(ticket, chain_id) do
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
