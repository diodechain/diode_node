### ----------------------------------------------------------------------
###
### Copyright (c) 2013 - 2018 Lee Sylvester and Xirsys LLC <experts@xirsys.com>
###
### All rights reserved.
###
### XTurn is licensed by Xirsys under the Apache
### License, Version 2.0. (the "License");
###
### you may not use this file except in compliance with the License.
### You may obtain a copy of the License at
###
###      http://www.apache.org/licenses/LICENSE-2.0
###
### Unless required by applicable law or agreed to in writing, software
### distributed under the License is distributed on an "AS IS" BASIS,
### WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
### See the License for the specific language governing permissions and
### limitations under the License.
###
### See LICENSE for the full license text.
###
### ----------------------------------------------------------------------

defmodule Xirsys.Sockets.Conn do
  @moduledoc """
  Socket connection object for TURN
  """
  require Logger

  alias Xirsys.Sockets.{Conn, Response, Socket}
  alias XMediaLib.Stun

  @vsn "0"
  @software "xirsys-turnserver"
  @nonce "5543438859252a7c" # fixed, for now.

  @type t :: %Conn{
          listener: :gen_tcp.socket() | :gen_udp.socket() | :ssl.sslsocket() | nil,
          message: binary() | nil,
          decoded_message: Stun.t() | nil,
          client_socket: :gen_tcp.socket() | :gen_udp.socket() | :ssl.sslsocket() | nil,
          client_ip: tuple() | nil,
          client_port: integer() | nil,
          server_ip: tuple() | nil,
          server_port: integer() | nil,
          is_control: boolean(),
          force_auth: boolean(),
          response: Response.t() | nil,
          halt: boolean() | nil
        }

  defstruct listener: nil,
            message: nil,
            decoded_message: nil,
            client_socket: nil,
            client_ip: nil,
            client_port: nil,
            server_ip: nil,
            server_port: nil,
            is_control: false,
            force_auth: false,
            response: nil,
            halt: nil

  @doc """
  Flags a connection object as halted, so it
  shouldn't be processed any further
  """
  @spec halt(Conn.t()) :: Conn.t()
  def halt(%Conn{} = conn),
    do: %Conn{conn | halt: true}

  @spec response(%Conn{}, atom() | integer(), binary() | any()) :: %Conn{}
  def response(conn, class, attrs \\ nil)

  def response(%Conn{} = conn, class, attrs) when is_atom(class),
    do: %Conn{conn | response: %Response{class: class, attrs: attrs}}

  def response(%Conn{} = conn, err, msg) when is_integer(err),
    do: %Conn{conn | response: %Response{err_no: err, message: msg}} |> Conn.halt()

  @doc """
  If a response message has been set, then we must notify the client according
  to the STUN and TURN specifications.
  """
  @spec send(%Conn{}) :: %Conn{}
  def send(%Conn{response: %Response{err_no: err, message: msg}} = conn) when is_integer(err) do
    conn
    |> build_response(err, msg)
    |> respond()
  end

  def send(%Conn{response: %Response{class: cls, attrs: attrs}} = conn) when is_atom(cls) do
    conn
    |> build_response(cls, attrs)
    |> respond()
  end

  def send(%Conn{} = conn) do
    conn
  end

  def send(v) do
    v
  end

  # Adjust Conn struct ready for response to end user.
  @spec build_response(%Conn{}, atom() | integer(), binary() | any()) :: %Conn{}
  defp build_response(%Conn{decoded_message: %Stun{} = turn} = conn, class, attrs)
       when is_atom(class) do
    new_attrs =
      cond do
        is_map(attrs) ->
          Map.put(attrs, :software, @software)

        true ->
          %{software: @software}
      end

    fingerprint = turn.integrity
    Logger.info("#{inspect(new_attrs)}")

    %Conn{
      conn
      | decoded_message: %Stun{turn | class: class, fingerprint: fingerprint, attrs: new_attrs}
    }
  end

  defp build_response(%Conn{decoded_message: %Stun{} = turn} = conn, err_no, err_msg)
       when is_integer(err_no) do
    new_attrs = %{
      error_code: {err_no, err_msg},
      nonce: @nonce,
      realm: realm(),
      software: @software
    }

    %Conn{conn | decoded_message: %Stun{turn | class: :error, attrs: new_attrs}}
  end

  # Encode Conn object and send to end user.
  @spec respond(%Conn{}) :: %Conn{}
  defp respond(%Conn{decoded_message: %Stun{} = turn} = conn) do
    case conn.client_socket do
      nil ->
        conn

      client_socket ->
        turn = %Stun{turn | fingerprint: true} # force fingerprint
        Socket.send(client_socket, Stun.encode(turn), conn.client_ip, conn.client_port)
        conn
    end
  end

  defp realm() do
    case Application.get_env(:xturn, :realm) do
      v when is_binary(v) -> v
      _ -> "xirsys.com"
    end
  end
end
