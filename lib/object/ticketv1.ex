# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule DiodeClient.Object.TicketV1 do
  alias DiodeClient.{ABI, Hash, Secp256k1, Wallet}
  require Record
  @behaviour DiodeClient.Object

  Record.defrecord(:ticketv1,
    server_id: nil,
    block_number: nil,
    fleet_contract: nil,
    total_connections: nil,
    total_bytes: nil,
    local_address: nil,
    device_signature: nil,
    server_signature: nil
  )

  @type ticket ::
          record(:ticketv1,
            server_id: binary(),
            block_number: integer(),
            fleet_contract: binary(),
            total_connections: integer(),
            total_bytes: integer(),
            local_address: binary(),
            device_signature: Secp256k1.signature(),
            server_signature: Secp256k1.signature() | nil
          )
  @type t ::
          record(:ticketv1,
            server_id: binary(),
            block_number: integer(),
            fleet_contract: binary(),
            total_connections: integer(),
            total_bytes: integer(),
            local_address: binary(),
            device_signature: Secp256k1.signature(),
            server_signature: Secp256k1.signature() | nil
          )
  @impl true
  def key(tck = ticketv1()) do
    device_address(tck)
  end

  @impl true
  def valid?(_serv) do
    # validity is given by the correct key value
    true
  end

  def device_address(tck = ticketv1()) do
    Secp256k1.recover!(
      device_signature(tck),
      device_blob(tck),
      :kec
    )
    |> Wallet.from_pubkey()
    |> Wallet.address!()
  end

  def device_address?(tck = ticketv1(), wallet) do
    Secp256k1.verify(
      Wallet.pubkey!(wallet),
      device_blob(tck),
      device_signature(tck),
      :kec
    )
  end

  def device_sign(tck = ticketv1(), private) do
    ticketv1(tck, device_signature: Secp256k1.sign(private, device_blob(tck), :kec))
  end

  def server_sign(tck = ticketv1(), private) do
    ticketv1(tck, server_signature: Secp256k1.sign(private, server_blob(tck), :kec))
  end

  @doc """
    Format for putting into a transaction with "SubmitTicketRaw"
  """
  def raw(tck = ticketv1()) do
    [rec, r, s] = Secp256k1.bitcoin_to_rlp(device_signature(tck))

    [
      block_number(tck),
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
      block_hash(tck),
      total_connections(tck),
      total_bytes(tck),
      local_address(tck),
      device_signature(tck)
    ]
  end

  def device_blob(tck = ticketv1()) do
    # From DiodeRegistry.sol:
    #   bytes32[] memory message = new bytes32[](6);
    #   message[0] = blockhash(blockHeight);
    #   message[1] = bytes32(fleetContract);
    #   message[2] = bytes32(nodeAddress);
    #   message[3] = bytes32(totalConnections);
    #   message[4] = bytes32(totalBytes);
    #   message[5] = localAddress;
    [
      block_hash(tck),
      fleet_contract(tck),
      server_id(tck),
      total_connections(tck),
      total_bytes(tck),
      Hash.sha3_256(local_address(tck))
    ]
    |> Enum.map(&ABI.encode("bytes32", &1))
    |> :erlang.iolist_to_binary()
  end

  def server_blob(tck = ticketv1()) do
    [device_blob(tck), device_signature(tck)]
    |> :erlang.iolist_to_binary()
  end

  def server_id(ticketv1(server_id: id)), do: id
  def chain_id(_ \\ nil), do: RemoteChain.diode_l1_fallback().chain_id()
  def epoch(t = ticketv1(block_number: n)), do: RemoteChain.epoch(chain_id(t), n)

  @impl true
  def block_number(ticketv1(block_number: n)), do: n
  def block_hash(ticketv1(block_number: n)), do: RemoteChain.blockhash(chain_id(), n)
  def device_signature(ticketv1(device_signature: signature)), do: signature
  def server_signature(ticketv1(server_signature: signature)), do: signature
  def fleet_contract(ticketv1(fleet_contract: fc)), do: fc
  def total_connections(ticketv1(total_connections: tc)), do: tc
  def total_bytes(ticketv1(total_bytes: tb)), do: tb
  def local_address(ticketv1(local_address: la)), do: la
end
