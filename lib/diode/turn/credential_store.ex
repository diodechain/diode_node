# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1

defmodule Diode.Turn.CredentialStore do
  @moduledoc false
  use GenServer

  @ttl_seconds 86_400
  @device_table :turn_cred_device
  @user_table :turn_cred_user
  @endpoint_table :turn_cred_endpoint

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Returns `{:ok, %{username: u, password: p, expires_at: unix, ttl_seconds: n}}` for this device.
  Reuses credentials until `expires_at` (24h from first issue).
  """
  def issue_or_get(device_address) when is_binary(device_address) do
    GenServer.call(__MODULE__, {:issue_or_get, device_address})
  end

  @doc """
  Looks up password and device for TURN USERNAME (binary or UTF-8 string).
  """
  def lookup_by_username(username) when is_binary(username) do
    now = System.os_time(:second)

    case :ets.lookup(@user_table, username) do
      [{^username, password, device, exp}] when exp > now ->
        {:ok, password, device}

      _ ->
        :error
    end
  end

  @doc """
  Associates a TURN client endpoint with the device that owns `username` (first authenticated traffic).
  """
  def register_endpoint(username, client_ip, client_port)
      when is_binary(username) and is_integer(client_port) do
    now = System.os_time(:second)

    case :ets.lookup(@user_table, username) do
      [{^username, _password, device, exp}] when exp > now ->
        :ets.insert(@endpoint_table, {{client_ip, client_port}, device})
        :ok

      _ ->
        :ok
    end
  end

  @doc "Resolve device for peer→client relay notifications (same client 5-tuple as control)."
  def lookup_endpoint(client_ip, client_port) do
    case :ets.lookup(@endpoint_table, {client_ip, client_port}) do
      [{_, device}] -> {:ok, device}
      [] -> :error
    end
  end

  @impl true
  def init(_) do
    :ets.new(@device_table, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@user_table, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@endpoint_table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:issue_or_get, device_address}, _from, state) do
    now = System.os_time(:second)

    reply =
      case :ets.lookup(@device_table, device_address) do
        [{^device_address, username, password, exp}] when exp > now ->
          {:ok,
           %{
             username: username,
             password: password,
             expires_at: exp,
             ttl_seconds: exp - now
           }}

        [{^device_address, old_username, _password, _exp}] ->
          :ets.delete(@user_table, old_username)
          :ets.delete(@device_table, device_address)
          issue_new(device_address, now)

        [] ->
          issue_new(device_address, now)
      end

    {:reply, reply, state}
  end

  defp issue_new(device_address, now) do
    exp = now + @ttl_seconds
    username = "d" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    password = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    :ets.insert(@device_table, {device_address, username, password, exp})
    :ets.insert(@user_table, {username, password, device_address, exp})

    {:ok,
     %{
       username: username,
       password: password,
       expires_at: exp,
       ttl_seconds: @ttl_seconds
     }}
  end
end
