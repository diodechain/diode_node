# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule TicketStoreSubmitScoringTest do
  use ExUnit.Case, async: false
  import TestHelper
  alias DiodeClient.{ETSLru, Object.Ticket, Wallet}
  alias DiodeClient.Object.TicketV2
  import TicketV2, only: [ticketv2: 1]

  @chain Chains.Anvil
  @ticket_grace 4096
  @cache :ticket_value_cache

  setup do
    reset()
    :ok
  end

  test "tickets_by_estimated_value matches legacy sort order" do
    fleet = RemoteChain.developer_fleet_address(@chain)
    epoch = RemoteChain.epoch(@chain) - 1
    chain_id = @chain.chain_id()
    seed_fleet_caches!(chain_id, fleet, epoch)

    tickets =
      wallets()
      |> Enum.take(5)
      |> Enum.with_index(1)
      |> Enum.map(fn {wallet, idx} ->
        build_ticket_struct(wallet,
          fleet_contract: fleet,
          epoch: epoch,
          total_bytes: @ticket_grace * idx,
          total_connections: idx
        )
      end)

    legacy_order =
      tickets
      |> Enum.sort_by(&TicketStore.estimate_ticket_value/1, :desc)
      |> Enum.map(&ticket_id/1)

    fast_order =
      tickets
      |> TicketStore.tickets_by_estimated_value()
      |> Enum.map(&ticket_id/1)

    assert fast_order == legacy_order
  end

  test "batch scoring values match single-ticket estimate_ticket_value" do
    wallet = hd(wallets())
    fleet = RemoteChain.developer_fleet_address(@chain)
    epoch = RemoteChain.epoch(@chain) - 1
    seed_fleet_caches!(@chain.chain_id(), fleet, epoch)

    ticket =
      build_ticket_struct(wallet,
        fleet_contract: fleet,
        epoch: epoch,
        total_bytes: @ticket_grace * 3,
        total_connections: 3
      )

    [{batch_value, ^ticket}] = TicketStore.tickets_with_estimated_values([ticket])
    assert batch_value == TicketStore.estimate_ticket_value(ticket)
  end

  test "fleet memoization returns identical fleet ratios for same fleet" do
    fleet = RemoteChain.developer_fleet_address(@chain)
    epoch = RemoteChain.epoch(@chain) - 1
    chain_id = @chain.chain_id()
    fleet_value = 50_000
    fleet_score = 200
    seed_fleet_caches!(chain_id, fleet, epoch, fleet_value * 100, fleet_score)

    tickets =
      wallets()
      |> Enum.take(3)
      |> Enum.with_index(1)
      |> Enum.map(fn {wallet, idx} ->
        build_ticket_struct(wallet,
          fleet_contract: fleet,
          epoch: epoch,
          total_bytes: @ticket_grace * idx,
          total_connections: idx
        )
      end)

    values =
      tickets
      |> TicketStore.tickets_with_estimated_values()
      |> Map.new(fn {value, tck} -> {tck, value} end)

    scores = Enum.map(tickets, &TicketStore.estimate_ticket_score/1)

    for {tck, score} <- Enum.zip(tickets, scores) do
      value = Map.fetch!(values, tck)
      assert value == div(score * fleet_value, fleet_score)
    end
  end

  defp seed_fleet_caches!(chain_id, fleet, epoch, fleet_balance \\ 1_000_000, fleet_score \\ 100) do
    ETSLru.put(@cache, {:fleet, chain_id, fleet, epoch + 1}, fleet_balance)
    ETSLru.put(@cache, {:fleet_score, fleet, chain_id, epoch}, fleet_score)
  end

  defp build_ticket_struct(wallet, opts) do
    fleet = Keyword.get(opts, :fleet_contract, RemoteChain.developer_fleet_address(@chain))
    epoch = opts[:epoch] || RemoteChain.epoch(@chain) - 1
    key = Wallet.privkey!(wallet)
    device = Wallet.address!(wallet)

    ticketv2(
      chain_id: @chain.chain_id(),
      server_id: Wallet.address!(Diode.wallet()),
      total_connections: Keyword.get(opts, :total_connections, 1),
      total_bytes: Keyword.get(opts, :total_bytes, @ticket_grace),
      local_address: "ticket_store_submit_scoring_test",
      epoch: epoch,
      fleet_contract: fleet
    )
    |> TicketV2.device_sign(key)
    |> Ticket.with_device_address(device)
  end

  defp ticket_id(tck) do
    {Ticket.device_address(tck), Ticket.fleet_contract(tck), Ticket.epoch(tck)}
  end
end
