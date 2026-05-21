# Diode Server
# Copyright 2021-2025 Diode
# Licensed under the Diode License, Version 1.1
defmodule KademliaLight.Node do
  @moduledoc """
  Ring member identity. Connection and retry state live in SQL / ETS.
  """
  alias DiodeClient.Wallet
  import Wallet

  defstruct [:node_id, :address, :ring_key]

  @type t :: %__MODULE__{
          node_id: Wallet.t(),
          address: <<_::160>>,
          ring_key: <<_::256>>
        }

  def new(wallet() = node_id) do
    address = Wallet.address!(node_id)
    ring_key = KademliaRing.key(node_id)

    %__MODULE__{node_id: node_id, address: address, ring_key: ring_key}
  end
end
