# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.EdgeV2Test do
  use ExUnit.Case, async: true
  alias DiodeClient.Wallet

  describe "message command recognition" do
    test "message command is recognized as async command" do
      # Create a mock state
      mock_wallet = Wallet.new()

      state = %{
        node_id: mock_wallet,
        fleet: nil,
        ports: %{},
        blocked: :queue.new(),
        compression: nil,
        extra_flags: [],
        inbuffer: nil,
        last_message: DateTime.utc_now(),
        last_ticket: nil,
        last_warning: nil,
        version: 1000,
        pid: self(),
        sender: nil,
        socket: nil
      }

      # Create a different device address for the message destination
      dest_wallet = Wallet.new()
      dest_address = Wallet.address!(dest_wallet)

      # Test message command
      message_cmd = ["message", dest_address, "test payload", %{"key" => "value"}]

      # Call handle_msg - message commands are handled asynchronously
      result = Network.EdgeV2.handle_msg(message_cmd, state)

      # Should return :async to indicate this is an async command
      assert result == :async
    end

    test "invalid message command format is not recognized" do
      # Create a mock state
      mock_wallet = Wallet.new()

      state = %{
        node_id: mock_wallet,
        fleet: nil,
        ports: %{},
        blocked: :queue.new(),
        compression: nil,
        extra_flags: [],
        inbuffer: nil,
        last_message: DateTime.utc_now(),
        last_ticket: nil,
        last_warning: nil,
        version: 1000,
        pid: self(),
        sender: nil,
        socket: nil
      }

      # Test invalid message command (missing parameters)
      invalid_cmd = ["message"]

      # Call handle_msg
      result = Network.EdgeV2.handle_msg(invalid_cmd, state)

      # Should return :async (falls through to async handling)
      assert result == :async
    end

    test "unknown command is not recognized" do
      # Create a mock state
      mock_wallet = Wallet.new()

      state = %{
        node_id: mock_wallet,
        fleet: nil,
        ports: %{},
        blocked: :queue.new(),
        compression: nil,
        extra_flags: [],
        inbuffer: nil,
        last_message: DateTime.utc_now(),
        last_ticket: nil,
        last_warning: nil,
        version: 1000,
        pid: self(),
        sender: nil,
        socket: nil
      }

      # Test unknown command
      unknown_cmd = ["unknown_command", "param1", "param2"]

      # Call handle_msg
      result = Network.EdgeV2.handle_msg(unknown_cmd, state)

      # Should return :async (falls through to async handling)
      assert result == :async
    end
  end
end
