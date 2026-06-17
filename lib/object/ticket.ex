defmodule DiodeClient.Object.Ticket do
  alias DiodeClient.Object.TicketV1
  alias DiodeClient.Object.TicketV2

  import DiodeClient.Object.TicketV1, only: [ticketv1: 0, ticketv1: 1]
  import DiodeClient.Object.TicketV2, only: [ticketv2: 0, ticketv2: 1]

  @type t :: DiodeClient.Object.TicketV1.t() | DiodeClient.Object.TicketV2.t()
  @type raw_t :: tuple()

  @spec mod(t() | raw_t()) :: module()
  def mod(t) when elem(t, 0) == :ticketv1, do: TicketV1
  def mod(t) when elem(t, 0) == :ticketv2, do: TicketV2

  @spec normalize(raw_t()) :: t()
  def normalize(tck = ticketv1()), do: tck
  def normalize(tck = ticketv2()), do: tck

  def normalize(
        {:ticketv1, server_id, block_number, fleet_contract, total_connections, total_bytes,
         local_address, device_signature, server_signature}
      ) do
    ticketv1(
      server_id: server_id,
      block_number: block_number,
      fleet_contract: fleet_contract,
      total_connections: total_connections,
      total_bytes: total_bytes,
      local_address: local_address,
      device_signature: device_signature,
      server_signature: server_signature,
      device_address: nil
    )
  end

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

  @spec key(raw_t()) :: binary()
  def key(tck), do: dispatch(tck, :key, [])

  @spec valid?(raw_t()) :: boolean()
  def valid?(tck), do: dispatch(tck, :valid?, [])

  @spec device_address(raw_t()) :: binary()
  def device_address(tck), do: dispatch(tck, :device_address, [])

  @spec with_device_address(raw_t(), binary()) :: t()
  def with_device_address(tck, device), do: dispatch(tck, :with_device_address, [device])

  @spec device_address?(raw_t(), term()) :: boolean()
  def device_address?(tck, wallet), do: dispatch(tck, :device_address?, [wallet])

  @spec device_sign(raw_t(), term()) :: t()
  def device_sign(tck, private), do: dispatch(tck, :device_sign, [private])

  @spec server_sign(raw_t(), term()) :: t()
  def server_sign(tck, private), do: dispatch(tck, :server_sign, [private])

  @spec raw(raw_t()) :: list()
  def raw(tck), do: dispatch(tck, :raw, [])

  @spec summary(raw_t()) :: list() | map()
  def summary(tck), do: dispatch(tck, :summary, [])

  @spec device_blob(raw_t()) :: binary()
  def device_blob(tck), do: dispatch(tck, :device_blob, [])

  @spec server_blob(raw_t()) :: binary()
  def server_blob(tck), do: dispatch(tck, :server_blob, [])

  @spec server_id(raw_t()) :: binary()
  def server_id(tck), do: dispatch(tck, :server_id, [])

  @spec chain_id(raw_t()) :: integer()
  def chain_id(tck), do: dispatch(tck, :chain_id, [])

  @spec epoch(raw_t()) :: integer()
  def epoch(tck), do: dispatch(tck, :epoch, [])

  @spec block_number(raw_t()) :: integer()
  def block_number(tck), do: dispatch(tck, :block_number, [])

  @spec device_signature(raw_t()) :: term()
  def device_signature(tck), do: dispatch(tck, :device_signature, [])

  @spec server_signature(raw_t()) :: term()
  def server_signature(tck), do: dispatch(tck, :server_signature, [])

  @spec fleet_contract(raw_t()) :: binary()
  def fleet_contract(tck), do: dispatch(tck, :fleet_contract, [])

  @spec total_connections(raw_t()) :: integer()
  def total_connections(tck), do: dispatch(tck, :total_connections, [])

  @spec total_bytes(raw_t()) :: integer()
  def total_bytes(tck), do: dispatch(tck, :total_bytes, [])

  @spec local_address(raw_t()) :: binary()
  def local_address(tck), do: dispatch(tck, :local_address, [])

  def score(tck), do: total_connections(tck) * 1024 + total_bytes(tck)

  def too_many_bytes?(tck) do
    total_bytes(tck) > 1024 * 1024 * 1024 * 1024 * 1024
  end

  def preferred_server_ids(tck) do
    la = local_address(tck)
    id = server_id(tck)

    case la do
      <<0, addr::binary-size(20)>> -> [addr, id]
      <<1, addr::binary-size(20)>> -> [id, addr]
      _ -> [id]
    end
  end

  defp dispatch(tck, fun, args) do
    tck = normalize(tck)

    case tck do
      ticketv1() -> apply(TicketV1, fun, [tck | args])
      ticketv2() -> apply(TicketV2, fun, [tck | args])
    end
  end
end
