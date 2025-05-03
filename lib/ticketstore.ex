# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule TicketStore do
  alias DiodeClient.{Base16, ETSLru, MetaTransaction, Object.Ticket, Rlp, Wallet}
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
    ETSLru.new(@ticket_value_cache, 1024)

    for tck <- TicketSql.tickets() do
      if Ticket.too_many_bytes?(tck) do
        TicketSql.delete(tck)
      end
    end

    {:ok, nil}
  end

  def clear() do
    TicketSql.delete_all()
  end

  def epoch() do
    div(System.os_time(:second), Chains.Moonbeam.epoch_duration())
  end

  def tickets(chainmod, epoch) when is_atom(chainmod) do
    tickets(chainmod.chain_id(), epoch)
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
  def maybe_submit_tickets() do
    maybe_submit_tickets(Chains.Moonbeam)
  end

  def maybe_submit_tickets(chainmod) when is_atom(chainmod) do
    maybe_submit_tickets(chainmod.chain_id())
  end

  def maybe_submit_tickets(chain_id) do
    blocknum = RemoteChain.peaknumber(chain_id)

    if not Diode.dev_mode?() and
         RemoteChain.epoch_progress(chain_id, blocknum) > 0.5 do
      epoch = RemoteChain.epoch(chain_id, blocknum)
      submit_tickets(chain_id, epoch - 1)
    end
  end

  def submit_tickets(chain_id, epoch) do
    update_fleet_scores(epoch)

    tickets(chain_id, epoch)
    |> submit_tickets()
  end

  def submit_tickets(tickets) when is_list(tickets) do
    # Submit max 10 tickets at a time
    tickets =
      tickets
      |> Enum.sort_by(&estimate_ticket_value/1, :desc)
      |> Stream.filter(fn tck -> validate_ticket(tck) == :ok end)
      |> Enum.take(10)

    if tickets != [] do
      if length(tickets) == 10 do
        Debouncer.delay(
          {__MODULE__, :submit_tickets},
          fn ->
            maybe_submit_tickets()
          end,
          :timer.minutes(5)
        )
      end

      submit_tickets_transaction(tickets)
    end
  end

  def submit_tickets_transaction(tickets) when is_list(tickets) do
    chain_id = Ticket.chain_id(hd(tickets))

    tx =
      Enum.flat_map(tickets, &Ticket.raw/1)
      |> Contract.Registry.submit_ticket_raw_tx(chain_id)

    case Shell.call_tx!(tx, "latest") do
      "0x" ->
        chain = RemoteChain.chainimpl(chain_id)
        nonce = RemoteChain.NonceProvider.nonce(chain_id)
        tx = %DiodeClient.Transaction{tx | nonce: nonce}

        txhash =
          if CallPermitAdapter.should_forward_metatransaction?(chain) do
            tx =
              MetaTransaction.sign(
                %MetaTransaction{
                  from: Diode.address(),
                  to: tx.to,
                  call: tx.data,
                  gaslimit: tx.gasLimit,
                  deadline: System.os_time(:second) + 3600,
                  value: tx.value,
                  nonce: tx.nonce,
                  chain_id: chain_id
                },
                Diode.wallet()
              )
              |> MetaTransaction.to_rlp()
              |> Rlp.encode!()

            case CallPermitAdapter.forward_metatransaction(chain, tx) do
              ["ok", txhash] -> txhash
              other -> {:error, other}
            end
          else
            Shell.submit_tx(tx)
          end

        if is_binary(txhash) do
          Enum.each(tickets, &store_submitted_ticket_score/1)

          Debouncer.delay(
            txhash,
            fn ->
              Enum.each(tickets, &update_submitted_ticket_score/1)
            end,
            :timer.minutes(5)
          )

          RemoteChain.NonceProvider.confirm_nonce(chain_id, tx.nonce)
          Logger.info("Submitted ticket tx #{inspect(txhash)} for #{length(tickets)} tickets")
          {:ok, txhash}
        else
          RemoteChain.NonceProvider.cancel_nonce(chain_id, tx.nonce)

          Logger.info(
            "Failed to submit ticket tx #{inspect(txhash)} for #{length(tickets)} tickets"
          )

          {:error, txhash}
        end

      {{:evmc_revert, reason}, _} ->
        {:error, "EVM error: #{inspect(reason)}"}

      other ->
        {:error, "Unknown error: #{inspect(other)}"}
    end
  end

  def validate_ticket(ticket) do
    cond do
      estimate_ticket_score(ticket) < 1_000_000 ->
        {:error, "Ticket score below 1mb"}

      estimate_ticket_value(ticket) < Shell.gwei(1) ->
        {:error, "Ticket value under 1gwei"}

      true ->
        Ticket.raw(ticket)
        |> Contract.Registry.submit_ticket_raw_tx(Ticket.chain_id(ticket))
        |> Shell.call_tx("latest")
        |> case do
          {:ok, "0x"} -> :ok
          {:error, %{"message" => reason}} -> {:error, "EVM error: #{inspect(reason)}"}
          other -> {:error, "#{inspect(other)}"}
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
    last = find(address, fleet, tepoch)

    cond do
      tepoch not in [epoch, epoch - 1] ->
        {:too_old, epoch - 1}

      last == nil or Ticket.too_many_bytes?(last) ->
        put_ticket(tck, address, fleet, tepoch)
        {:ok, Ticket.total_bytes(tck)}

      Ticket.total_bytes(tck) - Ticket.total_bytes(last) > 100_000_000 ->
        {:too_big_jump, epoch - 1}

      Ticket.score(last) < Ticket.score(tck) ->
        put_ticket(tck, address, fleet, tepoch)
        {:ok, max(0, Ticket.total_bytes(tck) - Ticket.total_bytes(last))}

      address != Ticket.device_address(last) ->
        Logger.warning("Ticked Signed on Fork RemoteChain")
        Logger.warning("Last: #{inspect(last)}\nTck: #{inspect(tck)}")
        put_ticket(tck, address, fleet, tepoch)
        {:ok, Ticket.total_bytes(tck)}

      true ->
        {:too_low, last}
    end
  end

  defp put_ticket(tck, device = <<_::160>>, fleet = <<_f::160>>, epoch) when is_integer(epoch) do
    key = {device, fleet, epoch}

    Debouncer.delay(key, fn ->
      addr = Ticket.device_address(tck) |> Base16.encode()
      bytes = Ticket.total_bytes(tck)
      conns = Ticket.total_connections(tck)
      epoch = Ticket.epoch(tck)
      Logger.info("Storing device ticket #{addr} #{bytes} bytes #{conns} conns @ #{epoch}")
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

  def estimate_ticket_score(tck) do
    ticket_score(tck) - ETSLru.get(@ticket_value_cache, ets_key(tck), 0)
  end

  def estimate_ticket_value(tck) do
    div(estimate_ticket_score(tck) * fleet_value(tck), fleet_score(tck))
  end

  defp ets_key(tck) do
    {:ticket, Ticket.chain_id(tck), Ticket.fleet_contract(tck), Ticket.device_address(tck),
     Ticket.epoch(tck)}
  end

  def fetch_submitted_ticket_score(tck) do
    chain_id = Ticket.chain_id(tck)
    node = Ticket.server_id(tck)
    fleet = Ticket.fleet_contract(tck)
    device = Ticket.device_address(tck)
    Contract.Registry.client_score(chain_id, fleet, node, device, "latest")
  end

  def fleet_value(tck) when is_tuple(tck) do
    fleet_value(Ticket.chain_id(tck), Ticket.fleet_contract(tck), Ticket.epoch(tck) + 1)
  end

  def fleet_value(chainmod, fleet, epoch) when is_atom(chainmod) do
    fleet_value(chainmod.chain_id(), fleet, epoch)
  end

  def fleet_value(chain_id, fleet, epoch) do
    ETSLru.fetch(@ticket_value_cache, {:fleet, chain_id, fleet, epoch}, fn ->
      n =
        min(
          RemoteChain.chainimpl(chain_id).epoch_block(epoch),
          RemoteChain.peaknumber(chain_id)
        )

      Contract.Registry.fleet(chain_id, fleet, n).currentBalance
    end)
    |> div(100)
  end

  def fleet_score(tck) when is_tuple(tck) do
    fleet_score(Ticket.fleet_contract(tck), Ticket.epoch(tck))
  end

  def fleet_score(fleet, epoch) do
    ETSLru.get(@ticket_value_cache, {:fleet_score, fleet, epoch}) ||
      update_fleet_scores(epoch)[fleet]
  end

  def update_fleet_scores(epoch) do
    tickets(epoch)
    |> Enum.group_by(fn tck -> Ticket.fleet_contract(tck) end)
    |> Enum.map(fn {fleet, tcks} ->
      total_score = Enum.map(tcks, fn tck -> ticket_score(tck) end) |> Enum.sum()
      ETSLru.put(@ticket_value_cache, {:fleet_score, fleet, epoch}, total_score)
      {fleet, total_score}
    end)
    |> Map.new()
  end

  def store_submitted_ticket_score(tck) do
    ticket_score = ticket_score(tck)

    case ETSLru.get(@ticket_value_cache, ets_key(tck), 0) do
      prev when prev >= ticket_score -> prev
      _other -> ETSLru.put(@ticket_value_cache, ets_key(tck), ticket_score)
    end
  end

  def update_submitted_ticket_score(tck) do
    ticket_score = fetch_submitted_ticket_score(tck)
    ETSLru.put(@ticket_value_cache, ets_key(tck), ticket_score)
  end

  def ticket_score(tck) when is_tuple(tck) do
    Ticket.score(tck)
  end

  def epoch_score(epoch \\ epoch()) when is_integer(epoch) do
    Enum.reduce(tickets(epoch), 0, fn tck, acc -> ticket_score(tck) + acc end)
  end
end
