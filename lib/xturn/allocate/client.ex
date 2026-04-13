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

defmodule Xirsys.XTurn.Allocate.Client do
  @moduledoc """
  """
  use GenServer
  require Logger
  @vsn "0"

  # Dialyzer: vendored Socket.send/4 and GenServer.terminate/2 contract disagree on success typing.
  @dialyzer [
    {:nowarn_function, terminate: 2},
    {:nowarn_function, send_data_channel: 4}
  ]

  @default_lifetime 600
  @channel_lifetime 600_000
  @permission_lifetime 300_000

  alias Xirsys.XTurn.Allocate.{Store, Client}
  alias Xirsys.XTurn.Channels.Store, as: Channels
  alias Xirsys.XTurn.Channels.Channel
  alias Xirsys.XTurn.Cache.Store, as: Cache
  alias Xirsys.XTurn.Tuple5
  alias Xirsys.XTurn.Timing, as: Time
  alias Xirsys.Sockets.Socket
  alias XMediaLib.Stun

  defmodule State do
    @moduledoc """
    TURN allocation state object
    """
    @vsn "0"
    defstruct id: nil,
              client_socket: nil,
              tuple5: nil,
              relayed_address: nil,
              relayed_socket: nil,
              requested_transport: :udp,
              dont_fragment: false,
              reserve_port: false,
              next_port: false,
              username: nil,
              passhash: nil,
              nonce: nil,
              refresh_time: nil,
              lifetime: 600,
              permissions: nil,
              channels: nil,
              bytes_in: 0,
              bytes_out: 0,
              peer_started: nil,
              peer_ended: nil,
              peer_id: nil,
              ns: nil
  end

  #########################################################################################################################
  # Interface functions
  #########################################################################################################################

  def start_link(id, client_socket, tuple5, lifetime),
    do: GenServer.start_link(__MODULE__, [id, client_socket, tuple5, lifetime])

  def create(id, client_socket, tuple5, lifetime),
    do: Xirsys.XTurn.Allocate.Supervisor.start_child(id, client_socket, tuple5, lifetime)

  def create(id, client_socket, tuple5),
    do: create(id, client_socket, tuple5, @default_lifetime)

  def destroy(pid),
    do: Xirsys.XTurn.Allocate.Supervisor.terminate_child(pid)

  def refresh(pid, lifetime),
    do: GenServer.cast(pid, {:refresh, lifetime})

  def count() do
    pid = Process.whereis(Xirsys.XTurn.Allocate.Supervisor)
    %{workers: workers} = Supervisor.count_children(pid)
    {:ok, workers}
  end

  def open_port_random(pid),
    do: open_port_random(pid, [])

  def open_port_random(pid, opts),
    do: GenServer.call(pid, {:open_port, :random, opts})

  def open_port_preferred(pid, port),
    do: open_port_preferred(pid, port, [])

  def open_port_preferred(pid, port, opts),
    do: GenServer.call(pid, {:open_port, {:preferred, port}, opts})

  def open_port_range(pid, min, max),
    do: open_port_range(pid, min, max, [])

  def open_port_range(pid, min, max, opts),
    do: GenServer.call(pid, {:open_port, {:range, min, max}, opts})

  def get_permission_cache(pid),
    do: GenServer.call(pid, :get_permission_cache)

  def set_peer_details(pid, ns, peer_id),
    do: GenServer.cast(pid, {:set_peer_details, ns, peer_id})

  def dont_fragment(pid),
    do: GenServer.call(pid, :dont_fragment)

  def clear_header(pid),
    do: GenServer.call(pid, :clear_header)

  def set_relay_address(pid, relay_address),
    do: GenServer.cast(pid, {:relay_address, relay_address})

  def add_permissions(pid, perms) when is_tuple(perms),
    do: GenServer.cast(pid, {:add_permissions, perms})

  def add_peer_channel(pid, channel_number, peer_address),
    do: GenServer.call(pid, {:add_channel, channel_number, peer_address})

  def remove_peer_channel(pid, channel_number, peer_address),
    do: GenServer.call(pid, {:remove_channel, channel_number, peer_address})

  def refresh_channel(pid, id),
    do: GenServer.cast(pid, {:refresh_channel, id})

  def send_channel(pid, channel, data, socket \\ nil, channel_cache \\ nil)

  def send_channel(pid, channel, <<_::binary>> = data, _, nil) when is_integer(channel),
    do: GenServer.cast(pid, {:send_channel, channel, data})

  def send_channel(pid, channel, <<_::binary>> = data, socket, channel_cache)
      when is_integer(channel) do
    send_data_channel(channel, data, socket, channel_cache)
    GenServer.cast(pid, {:log_data, data})
  end

  def send_indication(pid, peer_address, data, socket \\ nil, perms \\ nil)

  def send_indication(pid, {_, _} = peer_address, <<_::binary>> = data, nil, _perms) do
    Logger.debug("[XTurn] casting indication to peer #{inspect(peer_address)}")
    GenServer.cast(pid, {:send_indication, peer_address, data})
    :ok
  end

  def send_indication(pid, {pip, pport}, <<_::binary>> = data, socket, perms) do
    cond do
      not require_perms() or Cache.has_key?(perms, pip) ->
        Logger.debug("[XTurn] sending indication to peer #{inspect({pip, pport})}")
        Client.send_data(data, pip, pport, socket)
        GenServer.cast(pid, {:log_data, data})

      true ->
        Logger.debug("[XTurn] no permissions for peer #{inspect({pip, pport})}")
        :ok
    end
  end

  #########################################################################################################################
  # OTP functions
  #########################################################################################################################

  def init([id, client_socket, tuple5, lifetime]) do
    {:ok, perms} = Cache.init(@permission_lifetime)

    {:ok, chans} =
      Cache.init(@channel_lifetime, fn id ->
        Logger.debug("[XTurn] CHANNEL #{inspect(id)} REMOVED")
      end)

    {:ok,
     %State{
       id: id,
       client_socket: client_socket,
       tuple5: tuple5,
       refresh_time: Time.now(),
       lifetime: lifetime,
       peer_started: Time.local_time(),
       permissions: perms,
       channels: chans
     }, Time.milliseconds_left(Time.now(), lifetime)}
  end

  def handle_info(:timeout, %State{} = state),
    do: {:stop, :normal, state}

  def handle_info({:udp, socket, ip, in_port, packet}, %State{} = state) do
    {:ok, relay_port} = Socket.port(state.relayed_socket)

    Logger.debug(
      "[XTurn] relay:#{relay_port} received #{byte_size(packet)}B from #{:inet.ntoa(ip)}:#{in_port}"
    )

    Socket.setopts(socket)

    with true <- not require_perms() or Cache.has_key?(state.permissions, ip) do
      len = byte_size(packet)
      data = channel_or_stun(packet, {ip, in_port}, state.tuple5, len)

      result =
        Socket.send(
          state.client_socket,
          data,
          state.tuple5.client_address,
          state.tuple5.client_port
        )

      Logger.debug(
        "[XTurn] relay:#{relay_port} forwarded #{byte_size(data)}B to client #{:inet.ntoa(state.tuple5.client_address)}:#{state.tuple5.client_port} => #{inspect(result)}"
      )

      Socket.send_to_peer_hooks(%{
        client_ip: state.tuple5.client_address,
        client_port: state.tuple5.client_port,
        message: data
      })

      {:noreply, %State{state | bytes_in: state.bytes_in + byte_size(data)},
       Time.milliseconds_left(state)}
    else
      _ ->
        Logger.info("[XTurn] peer permission not available #{inspect(state.tuple5)}")
        {:noreply, state, Time.milliseconds_left(state)}
    end
  end

  def handle_call({:open_port, policy, opts}, from, %State{} = state),
    do: open_port_call({policy, opts}, from, state)

  def handle_call(:get_permission_cache, _from, %State{} = state),
    do: {:reply, {:ok, state.permissions}, state, Time.milliseconds_left(state)}

  def handle_call(:dont_fragment, _from, %State{} = state) do
    res = Socket.setopts(state.relayed_socket, [{:raw, 0, 10, <<2::native-size(32)>>}])
    {:reply, res, state, Time.milliseconds_left(state)}
  end

  def handle_call(:clear_header, _from, %State{} = state) do
    res = Socket.setopts(state.relayed_socket, [{:raw, 0, 10, <<0::native-size(32)>>}])
    {:reply, res, state, Time.milliseconds_left(state)}
  end

  def handle_call({:add_channel, channel_number, peer_address}, _from, %State{} = state) do
    channel = %Channel{id: channel_number, tuple5: state.tuple5, peer_address: peer_address}
    Logger.debug("[XTurn] ADDING CHANNEL #{inspect(channel_number)}")

    Channels.insert(
      channel_number,
      self(),
      peer_address,
      state.tuple5,
      state.relayed_socket,
      state.channels
    )

    Cache.append(state.channels, {channel_number, channel})
    {:reply, :ok, state, Time.milliseconds_left(state)}
  end

  def handle_call({:remove_channel, channel_number}, _from, %State{} = state) do
    Channels.delete(channel_number)
    Cache.remove(state.channels, channel_number)
    {:reply, :ok, state, Time.milliseconds_left(state)}
  end

  def handle_call({:remove_permission, id}, _from, %State{} = state) do
    Cache.remove(state.permissions, id)
    {:reply, :ok, state, Time.milliseconds_left(state)}
  end

  def handle_cast({:add_permissions, perm}, %State{} = state) do
    Logger.debug(
      "[XTurn] adding permissions #{inspect(state.permissions)} #{inspect(perm)} #{inspect(state.tuple5)}"
    )

    Cache.append(state.permissions, perm)
    {:noreply, state, Time.milliseconds_left(state)}
  end

  def handle_cast({:relay_address, relay_address}, %State{} = state),
    do: {:noreply, %State{state | relayed_address: relay_address}, Time.milliseconds_left(state)}

  def handle_cast({:set_peer_details, ns, peer_id}, %State{} = state),
    do: {:noreply, %State{state | ns: ns, peer_id: peer_id}, Time.milliseconds_left(state)}

  def handle_cast({:refresh, lifetime}, %State{} = state) do
    {:noreply, %State{state | refresh_time: Time.now()},
     Time.milliseconds_left(Time.now(), lifetime)}
  end

  def handle_cast({:refresh_channel, id}, %State{} = state) do
    Cache.append(state.channels, {id, nil})
    {:noreply, state, Time.milliseconds_left(state)}
  end

  def handle_cast({:send_channel, channel_number, data}, %State{} = state) do
    bytes_out = send_data_channel(channel_number, data, state.relayed_socket, state.channels)

    {:noreply, %State{state | bytes_out: state.bytes_out + bytes_out},
     Time.milliseconds_left(state)}
  end

  def handle_cast({:send_indication, {pip, pport} = _peer_address, data}, %State{} = state) do
    with true <- Cache.has_key?(state.permissions, pip) do
      send_data(data, pip, pport, state)

      {:noreply, %State{state | bytes_out: state.bytes_out + byte_size(data)},
       Time.milliseconds_left(state)}
    else
      _ ->
        {:noreply, state, Time.milliseconds_left(state)}
    end
  end

  def handle_cast({:log_data, data}, %State{} = state) do
    bytes_out = byte_size(data)

    {:noreply, %State{state | bytes_out: state.bytes_out + bytes_out},
     Time.milliseconds_left(state)}
  end

  def terminate(reason, %State{} = state) do
    relay_port =
      if state.relayed_socket, do: elem(Socket.port(state.relayed_socket), 1), else: "nil"

    Logger.debug(
      "[XTurn] Terminating relay:#{relay_port} reason=#{inspect(reason)} pid=#{inspect(self())}"
    )

    if state.relayed_socket,
      do: Socket.close(state.relayed_socket)

    Cache.keys(state.channels)
    |> Channels.delete()

    Cache.terminate(state.channels)
    Cache.terminate(state.permissions)
    Store.delete(state.id)
    :ok
  end

  #########################################################################################################################
  # Helper functions
  #########################################################################################################################

  defp open_port_call({policy, opts}, _from, %State{} = state) do
    case Socket.open_turn_port(Socket.server_local_ip(), policy, opts) do
      {:ok, socket} ->
        {:ok, port} = Socket.port(socket)

        {:reply, {:ok, socket, port}, %State{state | relayed_socket: socket},
         Time.milliseconds_left(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state, Time.milliseconds_left(state)}
    end
  end

  defp require_perms() do
    case Application.get_env(:xturn, :permissions) do
      %{required: required} -> required
      _ -> true
    end
  end

  def send_data(msg, state) do
    t5 = state.tuple5

    Logger.debug(
      "[XTurn] Returning data on #{inspect(t5.client_address)}:#{inspect(t5.client_port)}"
    )

    send_data(msg, t5.client_address, t5.client_port, state)
  end

  def send_data(msg, cip, cport, %Xirsys.Sockets.Socket{} = socket) do
    result = Socket.send(socket, msg, cip, cport)

    Logger.debug(
      "[XTurn] POSTING #{byte_size(msg)}B to #{:inet.ntoa(cip)}:#{cport} on #{inspect(socket)} => #{inspect(result)}"
    )

    result
  end

  def send_data(msg, cip, cport, state) do
    Logger.debug(
      "[XTurn] POSTING to #{inspect(cip)}:#{inspect(cport)} on relayed socket #{inspect(state.relayed_socket)}"
    )

    Socket.send(state.relayed_socket, msg, cip, cport)
  end

  def send_data_channel(channel_number, data, socket, channel_cache) do
    case Cache.fetch(channel_cache, channel_number) do
      {:ok, channel} ->
        {pip, pport} = channel.peer_address
        send_data(data, pip, pport, socket)
        byte_size(data)

      :error ->
        Logger.debug("[XTurn] send_data_channel: no cache entry for channel #{channel_number}")
        0
    end
  end

  defp channel_or_stun(packet, {_, _} = peer_address, %Tuple5{} = tuple5, len) do
    case Channels.lookup({peer_address, Tuple5.to_map(tuple5)}) do
      {:ok, [[channel_number, _client] | _]} ->
        <<channel_number::16, len::16>> <> packet

      _ ->
        attrs =
          %{}
          |> Map.put(:xor_peer_address, peer_address)
          |> Map.put(:data, packet)

        <<tid::96>> = :crypto.strong_rand_bytes(12)

        encoded =
          %XMediaLib.Stun{
            class: :indication,
            method: :data,
            transactionid: tid,
            integrity: false,
            fingerprint: true,
            attrs: attrs
          }
          |> Stun.encode()

        Logger.debug(
          "[XTurn] Data indication #{byte_size(encoded)}B peer=#{inspect(peer_address)}: #{Base.encode16(encoded)}"
        )

        encoded
    end
  end
end
