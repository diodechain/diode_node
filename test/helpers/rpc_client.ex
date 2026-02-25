# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule RpcClient do
  @moduledoc """
  WebSocket JSON-RPC client for testing message delivery over RPC protocol.
  Connects to /ws endpoint, authenticates with dio_ticket, sends/receives messages.
  """
  use WebSockex
  alias DiodeClient.Object.TicketV2, as: Ticket
  alias DiodeClient.{Base16, Certs, Rlp, Rlpx, Wallet}
  import ExUnit.Assertions
  import Ticket
  @chain Chains.Anvil
  @ticket_grace 4096

  def connect(port \\ nil) do
    port = port || Diode.rpc_port()
    url = "ws://localhost:#{port}/ws"
    parent = self()

    {:ok, pid} =
      WebSockex.start_link(url, __MODULE__, %{notifications: [], owner: parent})

    Process.sleep(100)
    pid
  end

  def authenticate(pid, client_num) do
    ticket = create_ticket(client_num)

    ticket_param =
      ticket
      |> ticket_to_rlp_param()
      |> Rlp.encode!()
      |> Base16.encode(false)

    send_request(pid, 1, "dio_ticket", [ticket_param])
    assert_receive {:rpc_response, %{"result" => nil}}, 2000
    :ok
  end

  def send_message(pid, destination_address, payload, metadata \\ %{}) do
    dest_b16 = Base16.encode(destination_address, false)
    payload_b16 = Base16.encode(payload, false)
    send_request(pid, 2, "dio_message", [dest_b16, payload_b16, metadata])
    assert_receive {:rpc_response, %{"result" => nil}}, 2000
    :ok
  end

  def send_request(pid, id, method, params) do
    msg = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    }

    WebSockex.send_frame(pid, {:text, Poison.encode!(msg)})
  end

  def get_notifications(pid) do
    send(pid, {:get_notifications, self()})

    receive do
      {:notifications, list} -> list
    after
      5_000 -> []
    end
  end

  # WebSockex callbacks
  @impl true
  def handle_connect(_conn, state) do
    {:ok, state}
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    case Poison.decode(msg) do
      {:ok, %{"method" => "dio_message_received"} = notification} ->
        send(state.owner, {:notification, notification})
        {:ok, %{state | notifications: [notification | state.notifications]}}

      {:ok, %{"id" => _id} = response} ->
        send(state.owner, {:rpc_response, response})
        {:ok, state}

      {:ok, _other} ->
        {:ok, state}

      _ ->
        {:ok, state}
    end
  end

  @impl true
  def handle_info({:get_notifications, from}, state) do
    send(from, {:notifications, Enum.reverse(state.notifications)})
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Private helpers
  defp create_ticket(client_num) do
    wallet = clientid(client_num)
    key = Wallet.privkey!(wallet)
    fleet = RemoteChain.developer_fleet_address(@chain)

    {conns, bytes} =
      case TicketStore.find(Wallet.address!(wallet), fleet, RemoteChain.epoch(@chain)) do
        nil -> {1, 0}
        tck -> {Ticket.total_connections(tck) + 1, Ticket.total_bytes(tck)}
      end

    ticketv2(
      chain_id: @chain.chain_id(),
      server_id: Wallet.address!(Diode.wallet()),
      total_connections: conns,
      total_bytes: bytes + @ticket_grace,
      local_address: "rpc_test",
      epoch: RemoteChain.epoch(@chain) - 1,
      fleet_contract: fleet
    )
    |> Ticket.device_sign(key)
  end

  defp ticket_to_rlp_param(tck) do
    [
      "ticketv2",
      Rlpx.uint2bin(Ticket.chain_id(tck)),
      Rlpx.uint2bin(Ticket.epoch(tck)),
      Ticket.fleet_contract(tck),
      Rlpx.uint2bin(Ticket.total_connections(tck)),
      Rlpx.uint2bin(Ticket.total_bytes(tck)),
      Ticket.local_address(tck),
      Ticket.device_signature(tck)
    ]
  end

  def clientid(n) do
    Wallet.from_privkey(Certs.private_from_file("./test/pems/device#{n}_certificate.pem"))
  end
end
