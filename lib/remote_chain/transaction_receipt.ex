# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule RemoteChain.TransactionReceipt do
  defstruct msg: nil,
            # state: nil,
            evmout: nil,
            gas_used: nil,
            return_data: nil,
            data: nil,
            logs: [],
            trace: nil

  @type t :: %RemoteChain.TransactionReceipt{
          msg: binary() | :ok | :evmc_revert,
          # state: RemoteChain.State.t() | nil,
          evmout: any(),
          gas_used: non_neg_integer() | nil,
          return_data: binary() | nil,
          data: binary() | nil,
          logs: []
        }
end
