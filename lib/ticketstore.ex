# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule TicketStore do
  alias Object.TicketV2
  alias Model.TicketSql
  alias Model.Ets
  use GenServer
  import TicketV2

  @ticket_value_cache :ticket_value_cache

  def start_link(ets_extra) do
    GenServer.start_link(__MODULE__, ets_extra, name: __MODULE__)
  end

  def epoch() do
    System.os_time(:second) |> TicketV2.time_to_epoch()
  end

  def init(ets_extra) do
    Ets.init(__MODULE__, ets_extra)
    EtsLru.new(@ticket_value_cache, 1024)
    {:ok, nil}
  end

  def clear() do
    TicketSql.delete_all()
  end

  def tickets(epoch) do
    Ets.all(__MODULE__)
    |> Enum.filter(fn tck -> TicketV2.epoch(tck) == epoch end)
    |> Enum.concat(TicketSql.tickets(epoch))
  end

  # Should be called on each new block
  def newblock(chain_id, blocknum) do
    blocktime = Chain.blocktime(chain_id, blocknum)

    if not Diode.dev_mode?() and
         rem(blocktime, TicketV2.epoch_length()) > TicketV2.epoch_length() / 2 do
      epoch = TicketV2.time_to_epoch(blocktime)
      submit_tickets(epoch - 1)
    end
  end

  def submit_tickets(epoch) do
    tickets =
      tickets(epoch)
      |> Enum.filter(fn tck ->
        estimate_ticket_value(tck) > 1_000_000
      end)
      |> Enum.filter(fn tck ->
        TicketV2.raw(tck)
        |> Contract.Registry.submit_ticket_raw_tx()
        |> Shell.call_tx("latest")
        |> case do
          {"", _gas_cost} ->
            true

          {{:evmc_revert, reason}, _} ->
            :io.format("TicketStore:submit_tickets(~p) ticket error: ~p~n", [epoch, reason])
            false

          other ->
            :io.format("TicketStore:submit_tickets(~p) ticket error: ~p~n", [epoch, other])
            false
        end
      end)

    if length(tickets) > 0 do
      tx =
        Enum.flat_map(tickets, fn tck ->
          store_ticket_value(tck)
          TicketV2.raw(tck)
        end)
        |> Contract.Registry.submit_ticket_raw_tx()

      case Shell.call_tx(tx, "latest") do
        {"", _gas_cost} ->
          Shell.submit_tx(tx)

        {{:evmc_revert, reason}, _} ->
          :io.format("TicketStore:submit_tickets(~p) transaction error: ~p~n", [epoch, reason])

        other ->
          :io.format("TicketStore:submit_tickets(~p) transaction error: ~p~n", [epoch, other])
      end
    end
  end

  @doc """
    Handling a ConnectionTicket
  """
  @spec add(TicketV2.t(), Wallet.t()) ::
          {:ok, non_neg_integer()} | {:too_low, TicketV2.t()} | {:too_old, integer()}
  def add(ticketv2(chain_id: chain_id) = tck, wallet) do
    tepoch = TicketV2.epoch(tck)
    epoch = Chain.epoch(chain_id)
    address = Wallet.address!(wallet)
    fleet = TicketV2.fleet_contract(tck)

    if epoch - 1 < tepoch do
      last = find(address, fleet, tepoch)

      case last do
        nil ->
          put_ticket(tck, address, fleet, tepoch)
          {:ok, TicketV2.total_bytes(tck)}

        last ->
          if TicketV2.total_connections(last) < TicketV2.total_connections(tck) or
               TicketV2.total_bytes(last) < TicketV2.total_bytes(tck) do
            put_ticket(tck, address, fleet, tepoch)
            {:ok, max(0, TicketV2.total_bytes(tck) - TicketV2.total_bytes(last))}
          else
            if address != TicketV2.device_address(last) do
              :io.format("Ticked Signed on Fork Chain~n")
              :io.format("Last: ~180p~nTick: ~180p~n", [last, tck])
              put_ticket(tck, address, fleet, tepoch)
              {:ok, TicketV2.total_bytes(tck)}
            else
              {:too_low, last}
            end
          end
      end
    else
      {:too_old, epoch - 1}
    end
  end

  defp put_ticket(tck, device = <<_::160>>, fleet = <<_f::160>>, epoch) when is_integer(epoch) do
    key = {device, fleet, epoch}

    Debouncer.delay(key, fn ->
      TicketSql.put_ticket(tck)
      Ets.remove(__MODULE__, key)
    end)

    Ets.put(__MODULE__, key, tck)
  end

  def find(device = <<_::160>>, fleet = <<_f::160>>, epoch) when is_integer(epoch) do
    Ets.lookup(__MODULE__, {device, fleet, epoch}, fn ->
      TicketSql.find(device, fleet, epoch)
    end)
  end

  def count(epoch) do
    TicketSql.count(epoch)
  end

  def estimate_ticket_value(tck = ticketv2(chain_id: chain_id, block_number: n)) do
    epoch = TicketV2.epoch(tck)
    device = TicketV2.device_address(tck)
    fleet = TicketV2.fleet_contract(tck)

    fleet_value =
      EtsLru.fetch(@ticket_value_cache, {:fleet, chain_id, fleet, epoch}, fn ->
        Contract.Registry.fleet_value(chain_id, 0, fleet, n)
      end)

    ticket_value = value(tck) * fleet_value

    case EtsLru.get(@ticket_value_cache, {:ticket, chain_id, fleet, device, epoch}) do
      nil -> ticket_value
      prev -> ticket_value - prev
    end
  end

  def store_ticket_value(tck = ticketv2(chain_id: chain_id, block_number: n)) do
    epoch = TicketV2.epoch(tck)
    device = TicketV2.device_address(tck)
    fleet = TicketV2.fleet_contract(tck)

    fleet_value =
      EtsLru.fetch(@ticket_value_cache, {:fleet, chain_id, fleet, epoch}, fn ->
        Contract.Registry.fleet_value(chain_id, 0, fleet, n)
      end)

    ticket_value = value(tck) * fleet_value

    case EtsLru.get(@ticket_value_cache, {:ticket, chain_id, fleet, device, epoch}) do
      prev when prev >= ticket_value ->
        prev

      _other ->
        EtsLru.put(@ticket_value_cache, {:ticket, chain_id, fleet, device, epoch}, ticket_value)
    end
  end

  @doc "Reports ticket value in 1024 blocks"
  def value(ticketv2() = tck) do
    div(TicketV2.total_bytes(tck) + TicketV2.total_connections(tck) * 1024, 1024)
  end

  def value(epoch) when is_integer(epoch) do
    Enum.reduce(tickets(epoch), 0, fn tck, acc -> value(tck) + acc end)
  end
end
