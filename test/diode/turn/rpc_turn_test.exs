# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1

defmodule Network.Rpc.TurnTest do
  use ExUnit.Case, async: false

  @device <<3::160>>

  setup do
    Application.ensure_all_started(:globals)
    prev = System.get_env("TURN_ENABLED")
    System.put_env("TURN_ENABLED", "1")
    Diode.Config.set("TURN_ENABLED", "1")
    start_supervised!(Diode.Turn.CredentialStore)

    on_exit(fn ->
      if prev, do: System.put_env("TURN_ENABLED", prev), else: System.delete_env("TURN_ENABLED")

      Diode.Config.set("TURN_ENABLED", prev || "0")
    end)

    :ok
  end

  test "dio_turn_open without device returns not authenticated" do
    assert {nil, 400, %{"code" => -32000, "message" => "not authenticated"}} =
             Network.Rpc.execute_dio("dio_turn_open", [], %{})
  end

  test "dio_turn_open with device returns credential map" do
    Process.put({:websocket_device, self()}, @device)

    assert {map, 200, nil} = Network.Rpc.execute_dio("dio_turn_open", [], %{})
    assert is_map(map)
    assert map["username"] |> is_binary()
    assert map["credential"] |> is_binary()
    assert map["realm"] |> is_binary()
    assert map["ttl_seconds"] > 0
    assert is_list(map["urls"])
  end
end
