# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Contract.Registry do
  @moduledoc """
    Wrapper for the DiodeRegistry contract functions
    as needed by the inner workings of the chain
  """

  def fleet_value(chain_id, type, address, blockRef) when type >= 0 and type <= 3 do
    call(chain_id, "ContractValue", ["uint8", "address"], [type, address], blockRef)
    |> :binary.decode_unsigned()
  end

  def epoch(chain_id, blockRef) do
    call(chain_id, "Epoch", [], [], blockRef)
    |> :binary.decode_unsigned()
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
  end
end
