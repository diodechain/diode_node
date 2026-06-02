# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.TicketSubmission do
  @moduledoc """
  Shared ticket validation, TicketStore persistence, and Kademlia publish
  for Edge v2 and `dio_ticket` RPC.
  """
  alias DiodeClient.{Base16, Object, Object.Ticket, Rlpx, Wallet}
  import DiodeClient.Object.TicketV1, only: [ticketv1: 1]
  import DiodeClient.Object.TicketV2, only: [ticketv2: 1]

  @max_connections 1024 * 1024 * 1024 * 1024

  @spec decode_rlp_ticket(term()) :: {:ok, Ticket.t()} | {:error, String.t()}
  def decode_rlp_ticket(rlp) when is_list(rlp) do
    case rlp do
      [
        "ticketv2",
        chain_id,
        epoch,
        fleet,
        tc,
        tb,
        local_address,
        device_signature
      ] ->
        {:ok,
         ticketv2(
           chain_id: to_num(chain_id),
           server_id: Wallet.address!(Diode.wallet()),
           fleet_contract: fleet,
           total_connections: to_num(tc),
           total_bytes: to_num(tb),
           local_address: local_address,
           epoch: to_num(epoch),
           device_signature: device_signature
         )}

      ["ticket", block, fleet, tc, tb, local_address, device_signature] ->
        {:ok,
         ticketv1(
           server_id: Wallet.address!(Diode.wallet()),
           fleet_contract: fleet,
           total_connections: to_num(tc),
           total_bytes: to_num(tb),
           local_address: local_address,
           block_number: to_num(block),
           device_signature: device_signature
         )}

      _ ->
        {:error, "invalid ticket"}
    end
  rescue
    _ -> {:error, "invalid ticket"}
  end

  def decode_rlp_ticket(_), do: {:error, "invalid ticket"}

  @spec submit(Ticket.t(), Wallet.t(), keyword()) ::
          {:ok, non_neg_integer()}
          | {:error, String.t()}
          | {:error, String.t(), term()}
          | {:error, String.t(), Ticket.t(), non_neg_integer()}
  def submit(ticket, device_wallet, opts \\ []) do
    version = Keyword.get(opts, :version, 1000)
    reset_usage? = Keyword.get(opts, :reset_usage?, false)

    with :ok <- validate(ticket, device_wallet),
         signed = Ticket.server_sign(ticket, Wallet.privkey!(Diode.wallet())),
         :ok <- maybe_reset_usage(signed, device_wallet, reset_usage?),
         result <- TicketStore.add(signed, device_wallet, version) do
      case result do
        {:ok, bytes} ->
          store_in_kademlia(signed)
          {:ok, bytes}

        {:too_old, min} ->
          {:error, "too_old", min}

        {:too_big_jump, min} ->
          {:error, "too_big_jump", min}

        {:too_low, last, usage} ->
          {:error, "too_low", last, usage}
      end
    end
  end

  @spec validate(Ticket.t(), Wallet.t()) :: :ok | {:error, String.t()}
  def validate(ticket, device_wallet) do
    cond do
      Ticket.epoch(ticket) + 1 < RemoteChain.epoch(Ticket.chain_id(ticket)) ->
        {:error, "epoch number too low"}

      Ticket.epoch(ticket) > RemoteChain.epoch(Ticket.chain_id(ticket)) ->
        {:error, "epoch number too high"}

      Ticket.too_many_bytes?(ticket) ->
        {:error, "too many bytes"}

      Ticket.total_connections(ticket) > @max_connections ->
        {:error, "too many connections"}

      not Ticket.device_address?(ticket, device_wallet) ->
        {:error, "signature mismatch"}

      true ->
        FleetValidation.ensure_valid(ticket)
    end
  end

  defp maybe_reset_usage(ticket, device_wallet, true) do
    device = Wallet.address!(device_wallet)
    fleet = Ticket.fleet_contract(ticket)
    epoch = Ticket.epoch(ticket)

    last_ticket = TicketStore.find(device, fleet, epoch)

    if last_ticket != nil do
      TicketStore.reset_device_usage(device, Ticket.total_bytes(last_ticket))
    else
      TicketStore.reset_device_usage(device, 0)
    end

    :ok
  end

  defp maybe_reset_usage(_ticket, _device_wallet, false), do: :ok

  @doc """
  Required byte baseline for the device at submit time: max(stored ticket bytes, ETS usage).
  Matches `TicketStore.add/3`.
  """
  @spec usage_for_device(binary(), Ticket.t()) :: non_neg_integer()
  def usage_for_device(device, ticket) do
    fleet = Ticket.fleet_contract(ticket)
    epoch = Ticket.epoch(ticket)

    last = TicketStore.find(device, fleet, epoch)
    ticket_usage = if last == nil, do: 0, else: Ticket.total_bytes(last)
    te = Ticket.epoch(ticket)

    max(
      ticket_usage,
      max(TicketStore.device_usage(device, te), TicketStore.device_usage(device))
    )
  end

  @doc "JSON-safe named fields from `Ticket.summary/1` (hex-encoded)."
  @spec encode_summary(Ticket.t()) :: map()
  def encode_summary(ticket) do
    case Ticket.mod(ticket) do
      DiodeClient.Object.TicketV2 ->
        %{
          "chain_id" => encode16(Ticket.chain_id(ticket)),
          "epoch" => encode16(Ticket.epoch(ticket)),
          "total_connections" => encode16(Ticket.total_connections(ticket)),
          "total_bytes" => encode16(Ticket.total_bytes(ticket)),
          "local_address" => encode16(Ticket.local_address(ticket)),
          "device_signature" => encode16(Ticket.device_signature(ticket))
        }

      DiodeClient.Object.TicketV1 ->
        [block_hash, conns, bytes, local_address, device_signature] = Ticket.summary(ticket)

        %{
          "block_hash" => encode16(block_hash),
          "total_connections" => encode16(conns),
          "total_bytes" => encode16(bytes),
          "local_address" => encode16(local_address),
          "device_signature" => encode16(device_signature)
        }
    end
  end

  @doc "RPC `data` payload for `dio_ticket` too_low errors."
  @spec too_low_data(Ticket.t(), Wallet.t(), non_neg_integer() | nil) :: map()
  def too_low_data(ticket, device_wallet, required_usage \\ nil) do
    device = Wallet.address!(device_wallet)

    usage =
      required_usage ||
        usage_for_device(device, ticket)

    %{
      "usage" => encode16(usage),
      "summary" => encode_summary(ticket)
    }
  end

  defp store_in_kademlia(ticket) do
    key = Object.key(ticket)

    Debouncer.immediate(
      key,
      fn ->
        Model.KademliaSql.put_object(KademliaLight.hash(key), Object.encode!(ticket))
        KademliaLight.store(ticket)
      end,
      15_000
    )
  end

  defp to_num(bin) when is_binary(bin), do: Rlpx.bin2uint(bin)
  defp to_num(num) when is_integer(num), do: num

  defp encode16(value) when is_binary(value), do: Base16.encode(value, false)
  defp encode16(value) when is_integer(value) and value >= 0, do: Base16.encode(value, false)
end
