defmodule DiodeClient.Object.Ticket do
  import DiodeClient.Object.TicketV1, only: [ticketv1: 0]
  import DiodeClient.Object.TicketV2, only: [ticketv2: 0]

  def mod(ticketv1()), do: DiodeClient.Object.TicketV1
  def mod(ticketv2()), do: DiodeClient.Object.TicketV2

  def key(tck), do: mod(tck).key(tck)
  def valid?(tck), do: mod(tck).valid?(tck)
  def device_address(tck), do: mod(tck).device_address(tck)

  def device_address?(tck, wallet), do: mod(tck).device_address?(tck, wallet)
  def device_sign(tck, private), do: mod(tck).device_sign(tck, private)
  def server_sign(tck, private), do: mod(tck).server_sign(tck, private)
  def raw(tck), do: mod(tck).raw(tck)
  def summary(tck), do: mod(tck).summary(tck)
  def device_blob(tck), do: mod(tck).device_blob(tck)
  def server_blob(tck), do: mod(tck).server_blob(tck)
  def server_id(tck), do: mod(tck).server_id(tck)
  def chain_id(tck), do: mod(tck).chain_id(tck)
  def epoch(tck), do: mod(tck).epoch(tck)

  def block_number(tck), do: mod(tck).block_number(tck)
  def block_hash(tck), do: mod(tck).block_hash(tck)
  def device_signature(tck), do: mod(tck).device_signature(tck)
  def server_signature(tck), do: mod(tck).server_signature(tck)
  def fleet_contract(tck), do: mod(tck).fleet_contract(tck)
  def total_connections(tck), do: mod(tck).total_connections(tck)
  def total_bytes(tck), do: mod(tck).total_bytes(tck)
  def local_address(tck), do: mod(tck).local_address(tck)
  def score(tck), do: total_connections(tck) * 1024 + total_bytes(tck)

  def too_many_bytes?(tck) do
    total_bytes(tck) > 1024 * 1024 * 1024 * 1024 * 1024
  end
end
