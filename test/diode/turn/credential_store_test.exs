# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1

defmodule Diode.Turn.CredentialStoreTest do
  use ExUnit.Case, async: false

  @device <<1::160>>

  setup do
    start_supervised!(Diode.Turn.CredentialStore)
    :ok
  end

  test "issue_or_get returns credentials" do
    assert {:ok, %{username: u, password: p, expires_at: exp, ttl_seconds: ttl}} =
             Diode.Turn.CredentialStore.issue_or_get(@device)

    assert is_binary(u) and String.starts_with?(u, "d")
    assert is_binary(p)
    assert is_integer(exp) and is_integer(ttl) and ttl > 0
  end

  test "repeat issue_or_get returns same username until expiry" do
    assert {:ok, %{username: u1}} = Diode.Turn.CredentialStore.issue_or_get(@device)
    assert {:ok, %{username: u2}} = Diode.Turn.CredentialStore.issue_or_get(@device)
    assert u1 == u2
  end

  test "lookup_by_username returns password for issued user" do
    {:ok, %{username: u, password: p}} = Diode.Turn.CredentialStore.issue_or_get(@device)
    assert {:ok, ^p, @device} = Diode.Turn.CredentialStore.lookup_by_username(u)
  end
end
