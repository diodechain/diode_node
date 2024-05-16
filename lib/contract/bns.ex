# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Contract.BNS do
  @moduledoc """
    Wrapper for the BNS contract functions
    as needed by the inner workings of the chain
  """

  def address() do
    0xAF60FAA5CD840B724742F1AF116168276112D6A6
    |> Hash.to_address()
  end

  def resolve_entry(name, blockRef \\ "latest") do
    [destination, owner, name, lockEnd, leaseEnd] =
      ["address", "address", "string", "uint256", "uint256"]
      |> ABI.decode_types(call("ResolveEntry", ["string"], [name], blockRef))

    %{destination: destination, owner: owner, name: name, lockEnd: lockEnd, leaseEnd: leaseEnd}
  end

  def crash_data() do
    "0x2f3f2ae1000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000116265726c696e2d7a65686c656e646f7266000000000000000000000000000000"
  end

  def crash() do
    code = Base16.decode(crash_data())

    Shell.raw(Diode.wallet(), code, [{:to, address()}])
    |> Shell.call_tx!("latest")
  end

  def crash_rpc() do
    method = "eth_call"

    params = [
      %{
        "data" => crash_data(),
        "gasPrice" => "0x0",
        "to" => Base16.encode(address())
      },
      "latest"
    ]

    # handle_jsonrpc: #{<<"id">> => 2,<<"jsonrpc">> => <<"2.0">>,
    #               <<"method">> => <<"eth_call">>,
    #               <<"params">> =>
    #                   [#{<<"data">> =>
    #                          <<"0x2f3f2ae1000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000116265726c696e2d7a65686c656e646f7266000000000000000000000000000000">>,
    #                      <<"gasPrice">> => <<"0x0">>,
    #                      <<"to">> =>
    #                          <<"0xaf60faa5cd840b724742f1af116168276112d6a6">>},
    #                    <<"latest">>]}

    Network.Rpc.handle_jsonrpc(%{"method" => method, "params" => params, "id" => 1})
  end

  defp call(name, types, values, blockRef) do
    Shell.call(Chains.Diode, address(), name, types, values, blockRef: blockRef)
    |> Base16.decode()
  end
end
