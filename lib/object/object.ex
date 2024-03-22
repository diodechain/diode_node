# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Object do
  @moduledoc """
    All objects are made of tuples {:type, value1, value2, ..., valueN, signature}
    The number of values are different but the last signature is a signature is
    always is the signature of BertExt.encode!([value1, value2, ..., valueN]))
    Also the signatures public key is always equal to the key
  """
  @type key :: <<_::160>>
  @callback key(tuple()) :: key()
  @callback block_number(tuple()) :: integer()
  @callback valid?(tuple()) :: boolean()

  def decode!(bin) when is_binary(bin) do
    BertExt.decode!(bin)
    |> decode_list!()
  end

  def decode_list!([type | values]) do
    [recordname(type) | values]
    |> List.to_tuple()
  end

  def decode_rlp_list!([
        ext = "ticketv2",
        server_id,
        chain_id,
        block_num,
        fleet_contract,
        total_connections,
        total_bytes,
        local_address,
        device_signature,
        server_signature
      ]) do
    {recordname(ext), server_id, chain_id, Rlpx.bin2num(block_num), fleet_contract,
     Rlpx.bin2num(total_connections), Rlpx.bin2num(total_bytes), local_address, device_signature,
     server_signature}
  end

  def decode_rlp_list!([
        ext = "ticket",
        server_id,
        block_num,
        fleet_contract,
        total_connections,
        total_bytes,
        local_address,
        device_signature,
        server_signature
      ]) do
    {recordname(ext), server_id, Rlpx.bin2num(block_num), fleet_contract,
     Rlpx.bin2num(total_connections), Rlpx.bin2num(total_bytes), local_address, device_signature,
     server_signature}
  end

  def decode_rlp_list!([ext = "server", host, edge_port, peer_port, signature]) do
    {recordname(ext), host, Rlpx.bin2num(edge_port), Rlpx.bin2num(peer_port), signature}
  end

  def decode_rlp_list!([ext = "server", host, edge_port, peer_port, version, extra, signature]) do
    extra = Enum.map(extra, fn [key, value] -> [key, Rlpx.bin2num(value)] end)

    {recordname(ext), host, Rlpx.bin2num(edge_port), Rlpx.bin2num(peer_port), version, extra,
     signature}
  end

  def decode_rlp_list!([
        ext = "channel",
        server_id,
        block_num,
        fleet_contract,
        type,
        name,
        params,
        signature
      ]) do
    {recordname(ext), server_id, Rlpx.bin2num(block_num), fleet_contract, type, name, params,
     signature}
  end

  def decode_rlp_list!([ext = "data", block_num, name, value, signature]) do
    {recordname(ext), Rlpx.bin2num(block_num), name, value, signature}
  end

  def encode!(record) do
    encode_list!(record)
    |> BertExt.encode!()
  end

  def encode_list!(record) do
    [type | values] = Tuple.to_list(record)
    [extname(type) | values]
  end

  @spec key(tuple()) :: binary()
  def key(record) do
    modname(record).key(record)
  end

  @spec block_number(tuple()) :: integer()
  def block_number(record) do
    modname(record).block_number(record)
  end

  @names [
    # record, external, module
    {:channel, "channel", Object.Channel},
    {:server, "server", Object.Server},
    {:data, "data", Object.Data},
    {:ticketv1, "ticket", Object.TicketV1},
    {:ticketv2, "ticketv2", Object.TicketV2}
  ]

  for {record, _ext, module} <- @names do
    def modname(unquote(record)), do: unquote(module)
  end

  def modname(tuple) do
    [type | _] = Tuple.to_list(tuple)
    modname(type)
  end

  for {record, ext, _module} <- @names do
    def extname(unquote(record)), do: unquote(ext)
  end

  for {record, ext, _mod} <- @names do
    def recordname(unquote(ext)), do: unquote(record)
  end
end
