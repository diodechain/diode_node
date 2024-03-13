# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule Object.ChannelV2 do
  require Record
  @behaviour Object

  Record.defrecord(:channelv2,
    server_id: nil,
    chain_id: nil,
    block_number: nil,
    fleet_contract: nil,
    type: nil,
    name: nil,
    params: [],
    signature: nil
  )

  @type channel ::
          record(:channelv2,
            server_id: binary(),
            chain_id: binary(),
            block_number: integer(),
            fleet_contract: binary(),
            type: binary(),
            name: binary(),
            params: [],
            signature: Secp256k1.signature()
          )

  def new(server_id, fleet, name, device_sig) do
    channelv2(server_id: server_id, fleet_contract: fleet, name: name, signature: device_sig)
  end

  @impl true
  @spec key(channel()) :: Object.key()
  def key(channelv2(fleet_contract: fleet, type: type, name: name, params: params)) do
    params = Rlp.encode!(params) |> Hash.keccak_256()
    Diode.hash(<<fleet::binary-size(20), type::binary, name::binary, params::binary>>)
  end

  @impl true
  def valid?(ch = channelv2()) do
    valid_type?(ch) and valid_device?(ch) and valid_params?(ch)
  end

  def valid_device?(ch = channelv2(fleet_contract: fleet)) do
    Contract.Fleet.device_allowlisted?(fleet, device_address(ch))
  end

  def valid_params?(channelv2(params: [])), do: true
  def valid_params?(_), do: false

  def valid_type?(channelv2(type: "mailbox")), do: true
  def valid_type?(channelv2(type: "broadcast")), do: true
  def valid_type?(_), do: false

  def device_address(rec = channelv2(signature: signature)) do
    Secp256k1.recover!(signature, message(rec), :kec)
    |> Wallet.from_pubkey()
    |> Wallet.address!()
  end

  defp message(
         channelv2(
           chain_id: chain_id,
           block_number: num,
           server_id: id,
           fleet_contract: fleet,
           type: type,
           name: name,
           params: params
         )
       ) do
    params = Rlp.encode!(params) |> Diode.hash()

    ["channelv2", id, Chain.blockhash(chain_id, num), fleet, type, name, params]
    |> Enum.map(&ABI.encode("bytes32", &1))
    |> :erlang.iolist_to_binary()
  end

  def sign(ch = channelv2(), private) do
    channelv2(ch, signature: Secp256k1.sign(private, message(ch), :kec))
  end

  @impl true
  def block_number(channelv2(block_number: block_number)), do: block_number
  def server_id(channelv2(server_id: server_id)), do: server_id
  def fleet_contract(channelv2(fleet_contract: fleet_contract)), do: fleet_contract
  def type(channelv2(type: type)), do: type
  def name(channelv2(name: name)), do: name
  def params(channelv2(params: params)), do: params
  def signature(channelv2(signature: signature)), do: signature
end
