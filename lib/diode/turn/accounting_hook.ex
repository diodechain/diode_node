# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1

defmodule Diode.Turn.AccountingHook do
  @moduledoc false
  use GenServer
  require Logger

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:process_message, :client, data}, state) do
    case data do
      %Xirsys.Sockets.Conn{message: msg, client_ip: cip, client_port: cport} ->
        account_client(msg, cip, cport)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_cast({:process_message, :peer, data}, state) do
    case data do
      %{message: msg, client_ip: cip, client_port: cport} ->
        account_peer(msg, cip, cport)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  defp account_client(msg, cip, cport) when is_binary(msg) do
    n = byte_size(msg)

    case XMediaLib.Stun.decode(msg) do
      {:ok, %XMediaLib.Stun{attrs: attrs}} when is_map(attrs) ->
        case Map.get(attrs, :username) do
          user when is_binary(user) ->
            Diode.Turn.CredentialStore.register_endpoint(user, cip, cport)

            case Diode.Turn.CredentialStore.lookup_by_username(user) do
              {:ok, _, device} ->
                TicketStore.increase_device_usage(device, n)

              _ ->
                :ok
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp account_peer(msg, cip, cport) when is_binary(msg) do
    n = byte_size(msg)

    case Diode.Turn.CredentialStore.lookup_endpoint(cip, cport) do
      {:ok, device} ->
        TicketStore.increase_device_usage(device, n)

      :error ->
        :ok
    end
  end
end
