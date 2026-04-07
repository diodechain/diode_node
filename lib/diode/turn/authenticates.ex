# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1

defmodule Diode.Turn.Authenticates do
  @moduledoc false
  require Logger
  alias Xirsys.Sockets.Conn
  alias XMediaLib.Stun

  def process(
        %Xirsys.Sockets.Conn{
          force_auth: force_auth,
          message: message,
          decoded_message: %XMediaLib.Stun{attrs: attrs}
        } =
          conn
      ) do
    auth = Application.get_env(:xturn, :authentication) || %{required: true}
    # attrs = Map.put_new(attrs, :realm, "diode")

    with {:skip, false} <- {:skip, not (Map.get(auth, :required, true) or force_auth)},
         true <- Map.has_key?(attrs, :username) and Map.has_key?(attrs, :realm),
         %XMediaLib.Stun{} = turn_dec <-
           process_integrity(message, Map.get(attrs, :username), Map.get(attrs, :realm)) do
      %Xirsys.Sockets.Conn{conn | decoded_message: turn_dec}
    else
      {:skip, true} ->
        conn

      _ ->
        if Map.get(auth, :required, true) or force_auth do
          conn
          |> Conn.response(401, "Unauthorized")
          |> Conn.halt()
        else
          conn
        end
    end
  end

  defp process_integrity(msg, username, realm) when is_binary(username) do
    Logger.debug("Diode.Turn.Authenticates checking USERNAME #{inspect(username)}")

    with {:ok, password, _device} <- Diode.Turn.CredentialStore.lookup_by_username(username),
         key <- username <> ":" <> realm <> ":" <> password,
         hkey <- :crypto.hash(:md5, key),
         {:ok, %XMediaLib.Stun{} = turn} <- Stun.decode(msg, hkey) do
      %XMediaLib.Stun{turn | key: hkey}
    else
      e ->
        Logger.warning("TURN integrity failed: #{inspect(e)}")
        false
    end
  end
end
