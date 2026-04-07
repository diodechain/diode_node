# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1

defmodule Diode.Turn do
  @moduledoc false
  require Logger

  @doc """
  Issues or returns existing TURN credentials for `device_address` (20-byte binary).
  Returns `{:ok, map}` with string keys for JSON, or `{:error, reason}`.
  """
  def issue_credentials(device_address) when is_binary(device_address) do
    if not turn_enabled?() do
      {:error, :not_enabled}
    else
      case Diode.Turn.CredentialStore.issue_or_get(device_address) do
        {:ok, %{username: u, password: p, expires_at: exp, ttl_seconds: ttl}} ->
          host = turn_public_host()
          port = Diode.Config.get_int("TURN_LISTEN_PORT")
          realm = Diode.Config.get("TURN_REALM")

          {:ok,
           %{
             "username" => u,
             "credential" => p,
             "urls" => [
               "turn:#{host}:#{port}?transport=udp",
               "turn:#{host}:#{port}?transport=tcp"
             ],
             "realm" => realm,
             "ttl_seconds" => ttl,
             "expires_at" => exp
           }}

        other ->
          other
      end
    end
  end

  defp turn_public_host do
    Diode.Config.get("HOST") || "127.0.0.1"
  end

  def turn_enabled? do
    Diode.Config.get("TURN_ENABLED") in ~w(1 true)
  end

  @doc false
  def apply_xturn_runtime_config! do
    port = Diode.Config.get_int("TURN_LISTEN_PORT")
    bind_host = Diode.Config.get("TURN_BIND_HOST") || Diode.Config.get("HOST") || "0.0.0.0"
    bind_host = validate_bind_host(bind_host)
    {:ok, local_ip} = :inet.parse_address(String.to_charlist(bind_host))
    server_ip = resolve_server_ip_tuple()
    realm = Diode.Config.get("TURN_REALM") || "diode"

    listen = [{:udp, String.to_charlist(bind_host), port}]

    Application.put_env(:xturn, :listen, listen)
    Application.put_env(:xturn, :realm, realm)
    Application.put_env(:xturn, :server_ip, server_ip)
    Application.put_env(:xturn, :server_local_ip, local_ip)

    Application.put_env(:xturn, :authentication, %{
      required: true,
      username: :unused,
      credential: :unused
    })

    Application.put_env(:xturn, :permissions, %{required: false})
    Application.put_env(:xturn, :pipes, Diode.Turn.XturnDefaults.pipes_with_diode_auth())
    Application.put_env(:xturn, :client_hooks, [Diode.Turn.AccountingHook])
    Application.put_env(:xturn, :peer_hooks, [Diode.Turn.AccountingHook])
  end

  defp validate_bind_host("0.0.0.0"), do: "0.0.0.0"

  defp validate_bind_host(bind_host) do
    {:ok, ip} = :inet.parse_address(String.to_charlist(bind_host))

    case :gen_udp.open(0, [{:ip, ip}]) do
      {:ok, socket} ->
        :gen_udp.close(socket)
        bind_host

      {:error, :eaddrnotavail} ->
        Logger.error("TURN: bind address #{bind_host} not available, falling back to 0.0.0.0")
        "0.0.0.0"

      {:error, _} ->
        bind_host
    end
  end

  defp resolve_server_ip_tuple do
    ip_str = turn_public_host()

    case :inet.parse_address(String.to_charlist(ip_str)) do
      {:ok, ip} -> ip
      _ -> {127, 0, 0, 1}
    end
    |> IO.inspect(label: "resolve_server_ip_tuple")
  end
end
