# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule WireGuardServiceTest do
  use ExUnit.Case
  alias DiodeClient.Base16

  @moduletag :wireguard

  setup do
    # Check if WireGuard is available
    enabled = System.get_env("WIREGUARD_ENABLED") in ~w(1 true)

    if not enabled do
      :skip
    else
      # Set test config
      System.put_env("WIREGUARD_ENABLED", "1")
      System.put_env("WIREGUARD_INTERFACE", "diode_wg_test")
      System.put_env("WIREGUARD_LISTEN_PORT", "51821")
      System.put_env("WIREGUARD_TUNNEL_SUBNET", "10.0.1.0/24")
      System.put_env("WIREGUARD_POLL_INTERVAL_MS", "60000")

      # Reconfigure to pick up new values
      Diode.Config.configure()

      on_exit(fn ->
        # Clean up: stop service if running
        if pid = Process.whereis(WireGuardService) do
          GenServer.stop(pid)
        end

        # Try to delete test interface
        try do
          Wireguardex.delete_device("diode_wg_test")
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
      end)

      :ok
    end
  end

  @tag :skip
  test "add_peer with new device" do
    # Start service
    {:ok, _pid} = WireGuardService.start_link([])

    # Generate a test public key (32 bytes)
    device_address = <<0::160>> <> <<1::8>>
    public_key = :crypto.strong_rand_bytes(32)

    # Add peer
    assert :ok == WireGuardService.add_peer(device_address, public_key)
  end

  @tag :skip
  test "add_peer replaces existing peer" do
    {:ok, _pid} = WireGuardService.start_link([])

    device_address = <<0::160>> <> <<2::8>>
    old_public_key = :crypto.strong_rand_bytes(32)
    new_public_key = :crypto.strong_rand_bytes(32)

    # Add first peer
    assert :ok == WireGuardService.add_peer(device_address, old_public_key)

    # Replace with new peer
    assert :ok == WireGuardService.add_peer(device_address, new_public_key)
  end

  @tag :skip
  test "remove_peer with peer" do
    {:ok, _pid} = WireGuardService.start_link([])

    device_address = <<0::160>> <> <<3::8>>
    public_key = :crypto.strong_rand_bytes(32)

    # Add peer
    assert :ok == WireGuardService.add_peer(device_address, public_key)

    # Remove peer
    assert :ok == WireGuardService.remove_peer(device_address)
  end

  @tag :skip
  test "remove_peer without peer (idempotent)" do
    {:ok, _pid} = WireGuardService.start_link([])

    device_address = <<0::160>> <> <<4::8>>

    # Remove non-existent peer (should be idempotent)
    assert :ok == WireGuardService.remove_peer(device_address)
  end

  test "add_peer with invalid public key size" do
    {:ok, _pid} = WireGuardService.start_link([])

    device_address = <<0::160>> <> <<5::8>>
    # Only 3 bytes
    invalid_key = <<1, 2, 3>>

    assert {:error, :invalid_public_key} ==
             WireGuardService.add_peer(device_address, invalid_key)
  end
end
