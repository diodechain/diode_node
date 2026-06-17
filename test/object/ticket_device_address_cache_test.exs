# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule DiodeClient.Object.TicketDeviceAddressCacheTest do
  use ExUnit.Case, async: false
  import TestHelper
  alias DiodeClient.Object.Ticket
  alias DiodeClient.Object.TicketV2
  alias DiodeClient.{Secp256k1, Wallet}
  import TicketV2, only: [ticketv2: 1]
  import Edge2Client, only: [clientid: 1]

  @chain Chains.Anvil
  @ticket_grace 4096

  setup do
    reset()
    :ok
  end

  test "uncached ticket recovers device address from signature" do
    wallet = clientid(1)
    ticket = build_ticket(wallet)

    assert Ticket.device_address(ticket) == Wallet.address!(wallet)
    assert Ticket.device_address?(ticket, wallet)
  end

  test "cached device_address is returned without signature recovery" do
    wallet = clientid(1)
    ticket = build_ticket(wallet)
    recovered = Ticket.device_address(ticket)
    sentinel = <<1::160>>

    cached = Ticket.with_device_address(ticket, sentinel)

    assert count_recover_calls(fn ->
             assert Ticket.device_address(cached) == sentinel
           end) == 0

    assert recovered == Wallet.address!(wallet)
  end

  test "TicketSql restores device_address from db column for legacy blobs" do
    wallet = clientid(1)
    ticket = build_ticket(wallet)
    device = Ticket.device_address(ticket)
    fleet = Ticket.fleet_contract(ticket)
    epoch = Ticket.epoch(ticket)

    Model.Sql.query!(
      Model.TicketSql,
      "REPLACE INTO tickets (device, fleet, epoch, ticket) VALUES(?1, ?2, ?3, ?4)",
      [device, fleet, epoch, BertInt.encode!(ticket)]
    )

    [loaded] = Model.TicketSql.tickets(epoch)

    assert Ticket.device_address(loaded) == device

    assert count_recover_calls(fn ->
             assert Ticket.device_address(loaded) == device
           end) == 0
  end

  test "TicketStore persists and reloads cached device_address" do
    wallet = clientid(1)
    device = Wallet.address!(wallet)
    ticket = build_ticket(wallet, total_bytes: @ticket_grace, total_connections: 1)
    fleet = Ticket.fleet_contract(ticket)
    epoch = Ticket.epoch(ticket)

    assert {:ok, _} = Network.TicketSubmission.submit(ticket, wallet)

    stored = TicketStore.find(device, fleet, epoch)
    assert Ticket.device_address(stored) == device

    assert count_recover_calls(fn ->
             assert Ticket.device_address(stored) == device
           end) == 0
  end

  test "legacy ticketv1 tuple without device_address field is supported" do
    wallet = clientid(1)
    ticket = build_ticket(wallet)
    device = Wallet.address!(wallet)

    legacy =
      ticket
      |> Tuple.to_list()
      |> Enum.map(fn
        :ticketv2 -> :ticketv1
        chain_id when is_integer(chain_id) -> 7_315_576
        other -> other
      end)
      |> Enum.drop(-1)
      |> List.to_tuple()

    assert elem(legacy, 0) == :ticketv1
    assert Ticket.mod(legacy) == DiodeClient.Object.TicketV1
    assert Ticket.with_device_address(legacy, device)
    assert Ticket.device_address(Ticket.with_device_address(legacy, device)) == device
  end

  test "legacy ticketv2 tuple without device_address field is supported" do
    wallet = clientid(1)
    ticket = build_ticket(wallet)
    legacy = legacy_tuple(ticket)

    assert tuple_size(legacy) == tuple_size(ticket) - 1
    assert Ticket.mod(legacy) == DiodeClient.Object.TicketV2
    assert Ticket.device_address(legacy) == Wallet.address!(wallet)
  end

  test "TicketSql and TicketStore init load legacy ticket blobs" do
    wallet = clientid(1)
    ticket = build_ticket(wallet)
    device = Wallet.address!(wallet)
    fleet = Ticket.fleet_contract(ticket)
    epoch = Ticket.epoch(ticket)
    legacy = legacy_tuple(ticket)

    Model.Sql.query!(
      Model.TicketSql,
      "REPLACE INTO tickets (device, fleet, epoch, ticket) VALUES(?1, ?2, ?3, ?4)",
      [device, fleet, epoch, BertInt.encode!(legacy)]
    )

    [loaded] = Model.TicketSql.tickets(epoch)
    assert Ticket.device_address(loaded) == device

    assert count_recover_calls(fn ->
             assert Ticket.device_address(loaded) == device
           end) == 0

    Supervisor.terminate_child(Diode.Supervisor, TicketStore)

    assert {:ok, _pid} = Supervisor.restart_child(Diode.Supervisor, TicketStore)
  end

  test "submit and too_low behaviour unchanged with cached device_address" do
    wallet = clientid(1)
    device = Wallet.address!(wallet)
    epoch = RemoteChain.epoch(@chain) - 1
    fleet = RemoteChain.developer_fleet_address(@chain)

    high =
      build_ticket(wallet, epoch: epoch, total_bytes: 1_000_000, total_connections: 10)

    assert {:ok, _} = Network.TicketSubmission.submit(high, wallet)

    better_score =
      build_ticket(wallet, epoch: epoch, total_bytes: 50_000, total_connections: 5_000)

    assert {:error, "too_low", last, usage} =
             Network.TicketSubmission.submit(better_score, wallet)

    assert usage > 0
    assert usage >= Ticket.total_bytes(last)

    stored = TicketStore.find(device, fleet, epoch)
    assert Ticket.total_bytes(stored) == Ticket.total_bytes(high)
    assert Ticket.total_connections(stored) == Ticket.total_connections(high)
    assert Ticket.device_address(stored) == device
  end

  defp build_ticket(wallet, opts \\ []) do
    fleet = Keyword.get(opts, :fleet_contract, RemoteChain.developer_fleet_address(@chain))
    epoch = opts[:epoch] || RemoteChain.epoch(@chain) - 1
    key = Wallet.privkey!(wallet)

    ticketv2(
      chain_id: @chain.chain_id(),
      server_id: Wallet.address!(Diode.wallet()),
      total_connections: Keyword.get(opts, :total_connections, 1),
      total_bytes: Keyword.get(opts, :total_bytes, @ticket_grace),
      local_address: "ticket_device_address_cache_test",
      epoch: epoch,
      fleet_contract: fleet
    )
    |> TicketV2.device_sign(key)
  end

  defp legacy_tuple(ticket) do
    ticket
    |> Tuple.to_list()
    |> Enum.drop(-1)
    |> List.to_tuple()
  end

  defp count_recover_calls(fun) do
    test_pid = self()

    _ = :erlang.trace(test_pid, true, [:call])
    _ = :erlang.trace_pattern({Secp256k1, :recover!, 3}, true, [:local])

    try do
      fun.()
    after
      _ = :erlang.trace(test_pid, false, [:call])
      _ = :erlang.trace_pattern({Secp256k1, :recover!, 3}, false, [:local])
    end

    count_trace_messages(test_pid, 0)
  end

  defp count_trace_messages(test_pid, count) do
    receive do
      {:trace, ^test_pid, :call, {Secp256k1, :recover!, _args}} ->
        count_trace_messages(test_pid, count + 1)
    after
      0 -> count
    end
  end
end
