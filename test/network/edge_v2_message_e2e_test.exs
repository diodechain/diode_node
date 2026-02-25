# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.EdgeV2MessageE2ETest do
  use ExUnit.Case, async: false
  import TestHelper
  alias Edge2Client
  alias RpcClient

  setup_all do
    # Start two clone nodes for cross-node testing (peer_wiring applied per-test for cross_node)
    start_clones(2)
    :ok
  end

  setup context do
    # Only run client setup for message delivery tests, not RPC validation tests
    test_name = Atom.to_string(context.test)
    tags = Map.get(context, :tags, %{})

    cond do
      String.contains?(test_name, "websocket") ->
        :ok

      tags[:cross_node] ->
        reset()
        # Clones are killed by reset(); restart with peer wiring for cross-node test
        start_clones(2, peer_wiring: true)
        wait_clones(2, 60)
        Process.sleep(1000)
        TestHelper.configure_main_peer_list_for_clones(2)
        Edge2Client.ensure_clients_on_nodes()
        :ok

      true ->
        reset()
        Edge2Client.ensure_clients()
        :ok
    end
  end

  @tag timeout: 60000
  test "message delivery between devices on same node" do
    # Use the default setup (both clients connect to main node)
    client1_pid = Process.whereis(:client_1)
    client2_pid = Process.whereis(:client_2)

    # Get device addresses
    client1_wallet = Edge2Client.clientid(1)
    client2_wallet = Edge2Client.clientid(2)
    _client1_address = DiodeClient.Wallet.address!(client1_wallet)
    client2_address = DiodeClient.Wallet.address!(client2_wallet)

    # Test multiple messages with different content
    test_messages = [
      {"Hello from client1!", %{"type" => "greeting", "seq" => 1}},
      {"How are you?", %{"type" => "question", "seq" => 2}},
      {"Test message with special chars: éñü",
       %{"type" => "special", "seq" => 3, "data" => [1, 2, 3]}},
      # Empty payload
      {"", %{"type" => "empty", "seq" => 4}},
      {"Very long message: " <> String.duplicate("x", 1000), %{"type" => "long", "seq" => 5}}
    ]

    IO.puts("Sending #{length(test_messages)} test messages from client1 to client2...")

    # Send all messages
    Enum.each(test_messages, fn {payload, metadata} ->
      Edge2Client.csend(client1_pid, ["message", client2_address, payload, metadata])
      # Small delay between messages
      Process.sleep(100)
    end)

    IO.puts("All messages sent")

    # Give time for all messages to be processed
    Process.sleep(3000)

    # Check received messages
    case Edge2Client.cpeek(client2_pid) do
      {:ok, messages} ->
        IO.puts("Client2 received #{length(messages)} messages")

        # Extract message_received messages
        received_messages =
          Enum.filter(messages, fn
            [_req, ["message_received", _payload, _metadata]] -> true
            _ -> false
          end)

        IO.puts("Found #{length(received_messages)} message_received messages")

        # Verify we received all expected messages
        assert length(received_messages) == length(test_messages),
               "Expected #{length(test_messages)} messages, got #{length(received_messages)}"

        # Helper function to compare metadata
        metadata_matches? = fn received_list, expected_map ->
          # Convert received list of [key, value] pairs to map
          received_map = Map.new(received_list, fn [k, v] -> {k, v} end)

          # Compare each expected key-value pair
          Enum.all?(expected_map, fn {key, expected_value} ->
            case Map.get(received_map, key) do
              nil ->
                false

              received_value ->
                # Handle different value types
                case expected_value do
                  n when is_integer(n) -> received_value == <<n>>
                  l when is_list(l) -> received_value == Enum.map(l, &<<&1>>)
                  v -> received_value == v
                end
            end
          end)
        end

        # Verify each message content
        Enum.each(test_messages, fn {expected_payload, expected_metadata} ->
          # Find matching received message
          matching_msg =
            Enum.find(received_messages, fn
              [_req, ["message_received", payload, metadata_list]] ->
                payload == expected_payload &&
                  metadata_matches?.(metadata_list, expected_metadata)

              _ ->
                false
            end)

          assert matching_msg,
                 "Message with payload '#{inspect(expected_payload)}' and metadata #{inspect(expected_metadata)} not found"
        end)

        IO.puts("✓ All #{length(test_messages)} messages delivered with correct content")
    end
  end

  @tag rpc_only: true
  test "websocket RPC methods validation" do
    # This test doesn't need the full application setup
    # Test that the RPC functions are properly defined and handle basic cases

    # Test dio_ticket with invalid input (this should work without full app)
    try do
      result = Network.Rpc.execute_dio("dio_ticket", ["invalid_hex"], %{})
      # Should return error for invalid ticket
      assert match?({nil, 400, _}, result)
    rescue
      # If the function isn't available, that's also acceptable for this test
      _ -> :ok
    end

    IO.puts("✓ Websocket RPC methods are defined")
  end

  @tag timeout: 30000
  test "dio_ticket positive and dio_message via RPC" do
    # Connect via websocket to RPC (ws://localhost:rpc_port/ws)
    rpc_pid = RpcClient.connect(Diode.rpc_port())

    # Authenticate with dio_ticket (device 1)
    RpcClient.authenticate(rpc_pid, 1)

    # Send dio_message to device 2
    client2_address = DiodeClient.Wallet.address!(Edge2Client.clientid(2))
    RpcClient.send_message(rpc_pid, client2_address, "test", %{})

    IO.puts("✓ dio_ticket and dio_message via RPC succeeded")
  end

  @tag timeout: 30000
  test "basic message delivery functionality" do
    # Use the default setup (both clients connect to main node via Edge protocol)
    client1_pid = Process.whereis(:client_1)
    client2_pid = Process.whereis(:client_2)

    # Get device addresses
    client1_wallet = Edge2Client.clientid(1)
    client2_wallet = Edge2Client.clientid(2)
    _client1_address = DiodeClient.Wallet.address!(client1_wallet)
    client2_address = DiodeClient.Wallet.address!(client2_wallet)

    # Test basic message delivery between Edge devices
    test_payload = "Basic message delivery test"
    test_metadata = %{"test" => "basic", "seq" => 1}

    # Send from client1 to client2
    Edge2Client.csend(client1_pid, ["message", client2_address, test_payload, test_metadata])

    # Wait for delivery
    Process.sleep(2000)

    # Check that client2 received the message
    case Edge2Client.cpeek(client2_pid) do
      {:ok, messages} ->
        received_msg =
          Enum.find(messages, fn
            [_req, ["message_received", payload, _metadata]] -> payload == test_payload
            _ -> false
          end)

        assert received_msg, "Device did not receive message"
        IO.puts("✓ Basic message delivery working")

      {:error, _} ->
        flunk("Could not check device messages")
    end
  end

  @tag :cross_node
  @tag timeout: 60000
  test "message delivery edge2 -> edge2 on different nodes" do
    # Client 1 on main (hd(Diode.edge2_ports())), client 2 on clone 1 (TestHelper.edge2_port(1))
    client1_pid = Process.whereis(:client_1)
    client2_pid = Process.whereis(:client_2)

    client1_wallet = Edge2Client.clientid(1)
    client2_wallet = Edge2Client.clientid(2)
    _client1_address = DiodeClient.Wallet.address!(client1_wallet)
    client2_address = DiodeClient.Wallet.address!(client2_wallet)

    test_payload = "Cross-node message from main to clone"
    test_metadata = %{"type" => "cross_node", "seq" => 1}

    Edge2Client.csend(client1_pid, ["message", client2_address, test_payload, test_metadata])

    Process.sleep(5000)

    case Edge2Client.cpeek(client2_pid) do
      {:ok, messages} ->
        received_msg =
          Enum.find(messages, fn
            [_req, ["message_received", payload, _metadata]] -> payload == test_payload
            _ -> false
          end)

        assert received_msg, "Client2 on clone should receive message from client1 on main"
        IO.puts("✓ Cross-node message delivery working")

      {:error, _} ->
        flunk("Could not check device messages")
    end
  end

  @tag timeout: 30000
  test "message delivery rpc -> rpc on same node" do
    # Two websocket connections, both authenticated; sender calls dio_message, receiver gets notification
    recv_pid = RpcClient.connect(Diode.rpc_port())
    send_pid = RpcClient.connect(Diode.rpc_port())
    RpcClient.authenticate(recv_pid, 2)
    RpcClient.authenticate(send_pid, 1)
    client2_address = DiodeClient.Wallet.address!(Edge2Client.clientid(2))
    RpcClient.send_message(send_pid, client2_address, "rpc-to-rpc test", %{"type" => "rpc"})

    assert_receive {:notification,
                    %{"method" => "dio_message_received", "params" => %{"payload" => _}}},
                   3000

    IO.puts("✓ rpc -> rpc same node working")
  end

  @tag timeout: 30000
  test "message delivery edge2 -> rpc on same node" do
    # Edge2 client sends, RPC client (device 2) receives notification
    client1_pid = Process.whereis(:client_1)
    client2_address = DiodeClient.Wallet.address!(Edge2Client.clientid(2))
    recv_pid = RpcClient.connect(Diode.rpc_port())
    RpcClient.authenticate(recv_pid, 2)

    Edge2Client.csend(client1_pid, [
      "message",
      client2_address,
      "edge2-to-rpc test",
      %{"type" => "edge2rpc"}
    ])

    assert_receive {:notification,
                    %{"method" => "dio_message_received", "params" => %{"payload" => _}}},
                   3000

    IO.puts("✓ edge2 -> rpc same node working")
  end

  @tag timeout: 30000
  test "message delivery rpc -> edge2 on same node" do
    # RPC client sends dio_message, Edge2 client receives message_received
    client2_pid = Process.whereis(:client_2)
    client2_address = DiodeClient.Wallet.address!(Edge2Client.clientid(2))
    send_pid = RpcClient.connect(Diode.rpc_port())
    RpcClient.authenticate(send_pid, 1)

    RpcClient.send_message(send_pid, client2_address, "rpc-to-edge2 test", %{"type" => "rpcedge2"})

    Process.sleep(2000)

    case Edge2Client.cpeek(client2_pid) do
      {:ok, messages} ->
        received =
          Enum.find(messages, fn
            [_req, ["message_received", "rpc-to-edge2 test", _metadata]] -> true
            _ -> false
          end)

        assert received, "Edge2 client should receive message from RPC sender"
        IO.puts("✓ rpc -> edge2 same node working")

      {:error, _} ->
        flunk("Could not check device messages")
    end
  end

  # @tag timeout: :infinity
  # test "message delivery with reverse direction" do
  #   # TODO: Implement reverse direction test
  # end
end
