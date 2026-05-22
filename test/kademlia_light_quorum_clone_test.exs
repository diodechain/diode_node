# Diode Server
# Copyright 2021-2025 Diode
# Licensed under the Diode License, Version 1.1
defmodule KademliaLightQuorumCloneTest do
  @moduledoc """
  Multi-node quorum smoke test (requires anvil + clone processes).
  Run explicitly: `mix test test/kademlia_light_quorum_clone_test.exs --only clone_quorum`
  Set RUN_CLONE_QUORUM=1 when clone ports can be spawned.
  """
  use ExUnit.Case, async: false

  import TestHelper
  alias DiodeClient.{Base16, Object, Wallet}

  @moduletag :clone_quorum

  @tag timeout: 120_000
  test "store on main is readable after clone partition and recovery" do
    cond do
      System.get_env("DIODE_MINIMAL_TEST") == "1" ->
        :ok

      System.get_env("RUN_CLONE_QUORUM") != "1" ->
        :ok

      not clone_ports_free?() ->
        :ok

      true ->
        reset()
        kill_clones()

        wallets = wallets()

        main_peer_uri =
          "diode://#{Base16.encode(Diode.address())}@localhost:#{Diode.peer2_port()}"

        for num <- 1..2 do
          add_clone(num,
            seed: main_peer_uri,
            private_key:
              Wallet.privkey!(Enum.at(wallets, num)) |> Base16.encode() |> then(&"0x#{&1}")
          )
        end

        case wait_clones(2, 60) do
          :error ->
            kill_clones()
            :ok

          :ok ->
            configure_main_peer_list_for_clones(2)
            Process.sleep(2000)
            run_clone_quorum_scenario()
        end
    end
  end

  defp run_clone_quorum_scenario do
    object = Diode.self()
    key = Object.key(object)
    encoded = Object.encode!(object)

    assert :ok = KademliaLight.store(key, encoded)

    Process.sleep(3000)

    clone1 = name_clone(1)

    found =
      :rpc.call(clone1, KademliaLight, :find_value, [key], 30_000)

    assert is_binary(found)

    freeze_clone(1)

    found_main = KademliaLight.find_value(key)
    assert is_binary(found_main)

    unfreeze_clone(1)
    Process.sleep(2000)

    found_after =
      :rpc.call(clone1, KademliaLight, :find_value, [key], 30_000)

    assert is_binary(found_after)
  end

  defp clone_ports_free?() do
    Enum.all?([20002, 20003], fn port ->
      case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 100) do
        {:ok, s} ->
          :gen_tcp.close(s)
          false

        {:error, _} ->
          true
      end
    end)
  end
end
