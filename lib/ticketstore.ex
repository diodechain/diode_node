# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule TicketStore do
  alias Object.Ticket
  alias Model.TicketSql
  alias Model.Ets
  use GenServer
  require Logger

  @ticket_value_cache :ticket_value_cache

  def start_link(_args) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init([]) do
    Ets.init(__MODULE__)
    EtsLru.new(@ticket_value_cache, 1024)
    {:ok, nil}
  end

  def clear() do
    TicketSql.delete_all()
  end

  def epoch() do
    div(System.os_time(:second), Chains.Moonbeam.epoch_length())
  end

  def tickets(chain_id, epoch) do
    Ets.all(__MODULE__)
    |> Enum.filter(fn tck -> Ticket.epoch(tck) == epoch end)
    |> Enum.concat(TicketSql.tickets(epoch))
    |> Enum.filter(fn tck -> Ticket.chain_id(tck) == chain_id end)
  end

  def tickets(epoch) do
    Ets.all(__MODULE__)
    |> Enum.filter(fn tck -> Ticket.epoch(tck) == epoch end)
    |> Enum.concat(TicketSql.tickets(epoch))
  end

  # Should be called on each new block
  def newblock(chain_id, blocknum) do
    if not Diode.dev_mode?() and
         RemoteChain.epoch_progress(chain_id, blocknum) > 0.5 do
      epoch = RemoteChain.epoch(chain_id, blocknum)
      submit_tickets(chain_id, epoch - 1)
    end
  end

  def submit_tickets(chain_id, epoch) do
    tickets =
      tickets(chain_id, epoch)
      |> Enum.filter(fn tck ->
        estimate_ticket_value(tck) > 1_000_000
      end)
      |> Enum.filter(fn tck ->
        Ticket.raw(tck)
        |> Contract.Registry.submit_ticket_raw_tx(chain_id)
        |> Shell.call_tx("latest")
        |> case do
          {:ok, "0x"} ->
            true

          {:error, %{"message" => reason}} ->
            Logger.error("TicketStore:submit_tickets(#{epoch}) ticket error: #{inspect(reason)}")
            false

          other ->
            Logger.error("TicketStore:submit_tickets(#{epoch}) ticket error: #{inspect(other)}")
            false
        end
      end)

    if length(tickets) > 0 do
      tx =
        Enum.flat_map(tickets, fn tck ->
          store_ticket_value(tck)
          Ticket.raw(tck)
        end)
        |> Contract.Registry.submit_ticket_raw_tx(chain_id)

      case Shell.call_tx!(tx, "latest") do
        {"", _gas_cost} ->
          Shell.submit_tx(tx)

        {{:evmc_revert, reason}, _} ->
          Logger.error(
            "TicketStore:submit_tickets(#{epoch}) transaction error: #{inspect(reason)}"
          )

        other ->
          Logger.error(
            "TicketStore:submit_tickets(#{epoch}) transaction error: #{inspect(other)}"
          )
      end
    end
  end

  @doc """
    Handling a ConnectionTicket
  """
  def add(tck, wallet) do
    chain_id = Ticket.chain_id(tck)
    tepoch = Ticket.epoch(tck)
    epoch = RemoteChain.epoch(chain_id)
    address = Wallet.address!(wallet)
    fleet = Ticket.fleet_contract(tck)

    if tepoch in [epoch, epoch - 1] do
      last = find(address, fleet, tepoch)

      case last do
        nil ->
          put_ticket(tck, address, fleet, tepoch)
          {:ok, Ticket.total_bytes(tck)}

        last ->
          if Ticket.total_connections(last) < Ticket.total_connections(tck) or
               Ticket.total_bytes(last) < Ticket.total_bytes(tck) do
            put_ticket(tck, address, fleet, tepoch)
            {:ok, max(0, Ticket.total_bytes(tck) - Ticket.total_bytes(last))}
          else
            if address != Ticket.device_address(last) do
              Logger.warning("Ticked Signed on Fork RemoteChain")
              Logger.warning("Last: #{inspect(last)}\nTck: #{inspect(tck)}")
              put_ticket(tck, address, fleet, tepoch)
              {:ok, Ticket.total_bytes(tck)}
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

  def estimate_ticket_value(tck) do
    chain_id = Ticket.chain_id(tck)
    epoch = Ticket.epoch(tck)
    device = Ticket.device_address(tck)
    fleet = Ticket.fleet_contract(tck)
    ticket_score = ticket_score(tck) * fleet_value(chain_id, fleet, epoch + 1)

    case EtsLru.get(@ticket_value_cache, {:ticket, chain_id, fleet, device, epoch}) do
      nil -> ticket_score
      prev -> ticket_score - prev
    end
  end

  def fleet_value(chain_id, fleet, epoch) do
    EtsLru.fetch(@ticket_value_cache, {:fleet, chain_id, fleet, epoch}, fn ->
      n =
        min(
          RemoteChain.chainimpl(chain_id).epoch_block(epoch),
          RemoteChain.peaknumber(chain_id)
        )
        |> IO.inspect(label: "fleet_value")

      Contract.Registry.fleet(chain_id, fleet, n).currentBalance
    end)
    |> div(100)
  end

  def store_ticket_value(tck) do
    chain_id = Ticket.chain_id(tck)
    epoch = Ticket.epoch(tck)
    device = Ticket.device_address(tck)
    fleet = Ticket.fleet_contract(tck)
    ticket_value = ticket_score(tck) * fleet_value(chain_id, fleet, epoch)

    case EtsLru.get(@ticket_value_cache, {:ticket, chain_id, fleet, device, epoch}) do
      prev when prev >= ticket_value ->
        prev

      _other ->
        EtsLru.put(@ticket_value_cache, {:ticket, chain_id, fleet, device, epoch}, ticket_value)
    end
  end

  def ticket_score(tck) when is_tuple(tck) do
    Ticket.score(tck)
  end

  def epoch_score(epoch \\ epoch()) when is_integer(epoch) do
    Enum.reduce(tickets(epoch), 0, fn tck, acc -> ticket_score(tck) + acc end)
  end
end
