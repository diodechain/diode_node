# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule DiodeClient.Object.TicketV2 do
  alias DiodeClient.{ABI, Hash, Secp256k1, Wallet}
  require Record
  @behaviour DiodeClient.Object

  Record.defrecord(:ticketv2,
    server_id: nil,
    chain_id: nil,
    epoch: nil,
    fleet_contract: nil,
    total_connections: nil,
    total_bytes: nil,
    local_address: nil,
    device_signature: nil,
    server_signature: nil,
    device_address: nil
  )

  @type t ::
          record(:ticketv2,
            server_id: binary(),
            chain_id: integer(),
            epoch: integer(),
            fleet_contract: binary(),
            total_connections: integer(),
            total_bytes: integer(),
            local_address: binary(),
            device_signature: Secp256k1.signature(),
            server_signature: Secp256k1.signature() | nil,
            device_address: binary() | nil
          )
  @type raw :: t() | tuple()

  @spec normalize(tuple()) :: t()
  def normalize(t = ticketv2()), do: t

  def normalize(
        {:ticketv2, server_id, chain_id, epoch, fleet_contract, total_connections, total_bytes,
         local_address, device_signature, server_signature}
      ) do
    ticketv2(
      server_id: server_id,
      chain_id: chain_id,
      epoch: epoch,
      fleet_contract: fleet_contract,
      total_connections: total_connections,
      total_bytes: total_bytes,
      local_address: local_address,
      device_signature: device_signature,
      server_signature: server_signature,
      device_address: nil
    )
  end

  @impl true
  def key(tck) do
    tck = normalize(tck)
    device_address(tck)
  end

  @impl true
  def valid?(_serv) do
    # validity is given by the correct key value
    true
  end

  @spec device_wallet(raw()) :: term()
  def device_wallet(tck) do
    tck = normalize(tck)

    Secp256k1.recover!(
      device_signature(tck),
      device_blob(tck),
      :kec
    )
    |> Wallet.from_pubkey()
  end

  @spec device_address(raw()) :: binary()
  def device_address(tck) do
    tck = normalize(tck)
    device_address_cached(tck)
  end

  defp device_address_cached(_tck = ticketv2(device_address: <<_::160>> = addr)), do: addr

  defp device_address_cached(tck = ticketv2()) do
    device_wallet(tck)
    |> Wallet.address!()
  end

  @spec with_device_address(raw(), binary()) :: t()
  def with_device_address(tck, device = <<_::160>>) do
    ticketv2(normalize(tck), device_address: device)
  end

  def device_address?(tck, wallet) do
    tck = normalize(tck)

    Secp256k1.verify(
      Wallet.pubkey!(wallet),
      device_blob(tck),
      device_signature(tck),
      :kec
    )
  end

  def device_sign(tck, private) do
    tck = normalize(tck)
    ticketv2(tck, device_signature: Secp256k1.sign(private, device_blob(tck), :kec))
  end

  def server_sign(tck, private) do
    tck = normalize(tck)
    ticketv2(tck, server_signature: Secp256k1.sign(private, server_blob(tck), :kec))
  end

  @doc """
    Format for putting into a transaction with "SubmitTicketRaw"
  """
  def raw(tck) do
    tck = normalize(tck)
    [rec, r, s] = Secp256k1.bitcoin_to_rlp(device_signature(tck))

    [
      epoch(tck),
      fleet_contract(tck),
      server_id(tck),
      total_connections(tck),
      total_bytes(tck),
      Hash.sha3_256(local_address(tck)),
      r,
      s,
      rec
    ]
  end

  def summary(tck) do
    [
      chain_id(tck),
      epoch(tck),
      total_connections(tck),
      total_bytes(tck),
      local_address(tck),
      device_signature(tck)
    ]
  end

  def device_blob(tck) do
    tck = normalize(tck)

    [
      chain_id(tck),
      epoch(tck),
      fleet_contract(tck),
      server_id(tck),
      total_connections(tck),
      total_bytes(tck),
      Hash.sha3_256(local_address(tck))
    ]
    |> Enum.map(&ABI.encode("bytes32", &1))
    |> :erlang.iolist_to_binary()
  end

  def server_blob(tck) do
    tck = normalize(tck)

    [device_blob(tck), device_signature(tck)]
    |> :erlang.iolist_to_binary()
  end

  def server_id(tck) do
    ticketv2(server_id: id) = normalize(tck)
    id
  end

  def chain_id(tck) do
    ticketv2(chain_id: chain_id) = normalize(tck)
    chain_id
  end

  def epoch(tck) do
    ticketv2(epoch: epoch) = normalize(tck)
    epoch
  end

  @impl true
  def block_number(tck) do
    t = normalize(tck)
    ticketv2(epoch: epoch) = t
    epoch * 0xFFFFFFFFFFFFFFFF + total_bytes(t)
  end

  def device_signature(tck) do
    ticketv2(device_signature: signature) = normalize(tck)
    signature
  end

  def server_signature(tck) do
    ticketv2(server_signature: signature) = normalize(tck)
    signature
  end

  def fleet_contract(tck) do
    ticketv2(fleet_contract: fc) = normalize(tck)
    fc
  end

  def total_connections(tck) do
    ticketv2(total_connections: tc) = normalize(tck)
    tc
  end

  def total_bytes(tck) do
    ticketv2(total_bytes: tb) = normalize(tck)
    tb
  end

  def local_address(tck) do
    ticketv2(local_address: la) = normalize(tck)
    la
  end
end
