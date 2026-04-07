# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1

defmodule Diode.TurnTest do
  use ExUnit.Case, async: false

  @device <<1::160>>

  setup do
    Application.ensure_all_started(:globals)
    :ok
  end

  test "issue_credentials returns not_enabled when TURN is off" do
    prev = System.get_env("TURN_ENABLED")
    on_exit(fn -> restore_env("TURN_ENABLED", prev) end)
    System.put_env("TURN_ENABLED", "0")
    Diode.Config.set("TURN_ENABLED", "0")

    assert {:error, :not_enabled} = Diode.Turn.issue_credentials(@device)
  end

  test "issue_credentials returns urls and stable username when TURN is on" do
    prev = System.get_env("TURN_ENABLED")
    on_exit(fn -> restore_env("TURN_ENABLED", prev) end)
    System.put_env("TURN_ENABLED", "1")
    Diode.Config.set("TURN_ENABLED", "1")
    System.put_env("TURN_REALM", "diode")
    Diode.Config.set("TURN_REALM", "diode")
    start_supervised!(Diode.Turn.CredentialStore)

    assert {:ok, m1} = Diode.Turn.issue_credentials(@device)
    assert {:ok, m2} = Diode.Turn.issue_credentials(@device)

    assert m1["username"] == m2["username"]
    assert m1["credential"] == m2["credential"]
    assert m1["realm"] == "diode"
    assert is_integer(m1["ttl_seconds"])
    assert m1["ttl_seconds"] > 0
    assert is_list(m1["urls"])
    assert Enum.any?(m1["urls"], &String.contains?(&1, "transport=udp"))
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, val), do: System.put_env(key, val)
end
