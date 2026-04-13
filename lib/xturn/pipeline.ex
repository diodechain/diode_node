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

defmodule Xirsys.XTurn.Pipeline do
  @moduledoc """
  provides handers for TURN over STUN
  """
  # import ExProf.Macro
  require Logger
  @vsn "0"

  @stun_marker 0
  # @udp_proto <<17, 0, 0, 0>>
  # @tcp_proto <<6, 0, 0, 0>>

  alias Xirsys.Sockets.{Socket, Conn}

  alias XMediaLib.Stun

  @doc """
  Dispatches STUN/TURN input to the right handler. Must be called as a separate process.

  Clauses:

  * **STUN** — binary starting with the STUN marker; decodes and runs `do_request/1`.
  * **Channel Data** — [RFC5766](https://www.rfc-editor.org/rfc/rfc5766) section 11 (`:channeldata` pipe).
  * **Fallback** — logs an error when the message cannot be classified.
  """
  @spec process_message(Conn.t()) :: Conn.t() | false
  def process_message(
        %Xirsys.Sockets.Conn{message: <<@stun_marker::2, _::14, _rest::binary>> = msg} = conn
      ) do
    Logger.debug("[XTurn] TURN Data received")
    {:ok, turn} = Stun.decode(msg)
    do_request(%Xirsys.Sockets.Conn{conn | decoded_message: turn}) |> Conn.send()
  end

  def process_message(
        %Xirsys.Sockets.Conn{message: <<1::2, _num::14, length::16, _rest::binary>>} = conn
      ) do
    Logger.debug(
      "[XTurn] TURN channeldata request (length: #{length}) from client at ip:#{inspect(conn.client_ip)}, port:#{inspect(conn.client_port)}"
    )

    execute(conn, :channeldata)
  end

  def process_message(%Xirsys.Sockets.Conn{message: <<_::binary>>}) do
    Logger.error("[XTurn] Error in extracting TURN message")
    false
  end

  @doc """
  ### TODO: check to make sure all attributes are handled
  ### TODO: client TCP connection establishment [RFC6062] section 4.2

  attributes include:
    binding:          Handles STUN requests [RFC5389]
    allocate:         Handles TURN allocation requests [RFC5766] section 2.2 and section 5
    refresh:          Handles TURN refresh requests [RFC5766] section 7
    channelbind:      Handles TURN channelbind requests [RFC5766] section 11
    createperm:       Handles TURN createpermission requests [RFC5766] section 9
    send:             Handles TURN send indication requests [RFC5766] section 9
  """
  @spec do_request(Conn.t()) :: Conn.t() | false
  def do_request(
        %Xirsys.Sockets.Conn{decoded_message: %XMediaLib.Stun{class: :request, method: :binding}} =
          conn
      ) do
    Logger.debug(
      "[XTurn] STUN request from client at ip:#{inspect(conn.client_ip)}, port:#{inspect(conn.client_port)} with ip:#{inspect(conn.server_ip)}, port:#{inspect(conn.server_port)}"
    )

    attrs = %{
      xor_mapped_address: {conn.client_ip, conn.client_port},
      mapped_address: {conn.client_ip, conn.client_port},
      response_origin: {Socket.server_ip(), conn.server_port}
    }

    Conn.response(conn, :success, attrs)
  end

  def do_request(
        %Xirsys.Sockets.Conn{decoded_message: %XMediaLib.Stun{class: class, method: method}} =
          conn
      )
      when class in [:request, :indication] do
    Logger.debug(
      "[XTurn] TURN #{method} #{class} from client at ip:#{inspect(conn.server_ip)}, port:#{inspect(conn.server_port)}"
    )

    execute(conn, method)
  end

  def do_request(false) do
    Logger.error("[XTurn] Error: STUN process halted by server")
    false
  end

  def do_request(_) do
    Logger.error("[XTurn] Error in processing STUN message")
    false
  end

  # executes a given list of actions against a connection
  defp execute(%Xirsys.Sockets.Conn{} = conn, pipe) when is_atom(pipe) do
    Application.get_env(:xturn, :pipes, %{})
    |> Map.get(pipe, [])
    |> Enum.reduce(conn, &process/2)
  end

  defp process(_, %Xirsys.Sockets.Conn{halt: true} = conn), do: conn

  defp process(action, conn), do: apply(action, :process, [conn])
end
