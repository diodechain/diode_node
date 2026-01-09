# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.PortManager do
  alias Network.PortManager
  use GenServer

  @moduledoc """
  Port opening flow:

    Roles:
      Edge A - Remote TCP Client
      Client A - Local GenServer handling Edge A socket
      Client B - Local GenServer handling Edge B socket
      Edge B - Remote TCP Server

  1. Edge A send "portopen" via socket
  2. Client A receives "portopen" and calls PortManager.request_portopen -- BLOCKING
  3. Client B receives cast: {:pccb2_portopen, worker_pid, portname, physical_port, source_device_address, target_device_address, flags}
  4. Client B send "portopen" via socket to Edge B
  5. Client B receives "ack" or "deny" from Edge B
  6. Client B calls PortManager.confirm_portopen or PortManager.deny_portopen
  7. Client A receives PortCollection.request_portopen response


  Port GenServers who are sender/receiver have to implement these calls:application

  - handle_cast({:pccb2_portopen, worker_pid, portname, physical_port, source_device_address, target_device_address, flags}, state)
  - handle_cast({:pccb2_portclose, physical_port}, state)



  There are currently three access rights for "Ports" which are
  loosely following Posix conventions:
    1) r = Read
    2) w = Write
    3) s = Shared
  """

  defstruct ports: %{}, workers: %{}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__, hibernate_after: 5_000)
  end

  def init(_opts) do
    {:ok, %PortManager{}}
  end

  def request_portopen(portname, source_device_address, target_device_address, flags) do
    GenServer.call(
      __MODULE__,
      {:request_portopen, portname, source_device_address, target_device_address, flags},
      35_000
    )
  end

  def port_close(physical_port) do
    GenServer.call(__MODULE__, {:port_close, physical_port})
  end

  def port_find(physical_port) do
    GenServer.call(__MODULE__, {:port_find, physical_port})
  end

  def confirm_portopen(worker_pid) do
    send(worker_pid, :accept_portopen)
  end

  def deny_portopen(worker_pid, reason) do
    send(worker_pid, {:deny_portopen, reason})
  end

  def handle_call({:port_find, physical_port}, _from, state) do
    {:reply, Map.get(state.workers, physical_port), state}
  end

  def handle_call({:port_close, physical_port}, _from, state) do
    case state.workers[physical_port] do
      nil ->
        {:reply, {:error, "No worker found for physical port #{physical_port}"}, state}

      worker_pid ->
        send(worker_pid, :port_close)
        {:reply, :ok, %{state | workers: Map.delete(state.workers, worker_pid)}}
    end
  end

  def handle_call(
        {:request_portopen, portname, source_device_address, target_device_address, flags},
        from,
        state
      ) do
    case PubSub.subscribers({:edge, target_device_address}) do
      [] ->
        {:reply, {:error, "No listener found for device address #{hex(target_device_address)}"},
         state}

      [listener | _] ->
        spawn_worker(
          listener,
          %{
            portname: portname,
            source_device_address: source_device_address,
            target_device_address: target_device_address,
            flags: flags
          },
          from
        )
        |> case do
          {:ok, worker_pid, physical_port} ->
            {:noreply,
             %{
               state
               | workers:
                   Map.put(state.workers, worker_pid, physical_port)
                   |> Map.put(physical_port, worker_pid)
             }}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_info({:DOWN, _mon, _type, worker_pid, _reason}, state) do
    case state.workers[worker_pid] do
      nil ->
        {:noreply, state}

      physical_port ->
        {:noreply,
         %{state | workers: Map.delete(state.workers, worker_pid) |> Map.delete(physical_port)}}
    end
  end

  defp bind_port(:udp) do
    with {:ok, udp} <- :gen_udp.open(0, [:binary, {:active, false}, {:reuseaddr, true}]),
         {:ok, physical_port} <- :inet.port(udp) do
      udp_pid = spawn_link(__MODULE__, :worker_udp, [self(), udp])
      :gen_udp.controlling_process(udp, udp_pid)
      send(udp_pid, :init)
      {:ok, physical_port}
    end
  end

  defp bind_port(:tcp) do
    with {:ok, tcp} <- :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}]),
         {:ok, physical_port} <- :inet.port(tcp) do
      tcp_pid = spawn_link(__MODULE__, :worker_tcp, [self(), tcp])
      :gen_tcp.controlling_process(tcp, tcp_pid)
      send(tcp_pid, :init)
      {:ok, physical_port}
    end
  end

  defp spawn_worker(target_pid, msg, from = {source_pid, _ref}) do
    pid = self()
    target_device_address = msg.target_device_address
    source_device_address = msg.source_device_address
    port_type = if String.contains?(msg.flags, "u"), do: :udp, else: :tcp

    {worker_pid, _} =
      spawn_monitor(fn ->
        with {:ok, physical_port} <- bind_port(port_type) do
          send(pid, {:ok, physical_port})

          receive do
            :accept_portopen ->
              # GenServer.reply(from, {:ok, physical_port})
              :ok

            {:deny_portopen, _reason} ->
              # GenServer.reply(from, {:error, "Port open denied: #{inspect(reason)}"})
              exit({:shutdown, :port_open_denied})
          after
            10_000 ->
              # GenServer.reply(from, {:error, "Port open timed out"})
              exit({:shutdown, :port_open_timed_out})
          end

          reason = await_down(target_device_address, source_device_address)
          send(target_pid, {:pccb2_portclose, physical_port})
          send(source_pid, {:pccb2_portclose, physical_port})
          exit({:shutdown, reason})
        else
          {:error, reason} ->
            send(pid, {:error, reason})
        end
      end)

    receive do
      {:ok, physical_port} ->
        GenServer.cast(
          target_pid,
          {:pccb2_portopen, msg.portname, physical_port, source_device_address, msg.flags}
        )

        GenServer.reply(from, {:ok, physical_port})

        {:ok, worker_pid, physical_port}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp await_down(target_device_address, source_device_address) do
    receive do
      {:udp_down, reason} ->
        {:udp_down, reason}

      {:tcp_down, reason} ->
        {:tcp_down, reason}

      :port_close ->
        :port_closed

      {:bytes_sent, bytes} ->
        TicketStore.increase_device_usage(target_device_address, bytes)
        TicketStore.increase_device_usage(source_device_address, bytes)
        await_down(target_device_address, source_device_address)
    end
  end

  def worker_tcp(parent_pid, socket) do
    receive do
      :init -> :ok
    end

    {:ok, client1} = :gen_tcp.accept(socket, 35_000)
    {:ok, client2} = :gen_tcp.accept(socket, 35_000)
    :gen_tcp.close(socket)
    :inet.setopts(client1, [{:active, true}])
    :inet.setopts(client2, [{:active, true}])
    reason = loop_tcp(parent_pid, client1, client2)
    send(parent_pid, {:tcp_down, reason})
  end

  defp loop_tcp(parent_pid, client1, client2) do
    receive do
      msg -> msg
    end
    |> case do
      {:tcp_closed, ^client1} ->
        :gen_tcp.close(client1)
        :gen_tcp.close(client2)
        :closed_by_client1

      {:tcp_closed, ^client2} ->
        :gen_tcp.close(client1)
        :gen_tcp.close(client2)
        :closed_by_client2

      {:tcp_error, ^client1, reason} ->
        :gen_tcp.close(client1)
        :gen_tcp.close(client2)
        {:tcp_error_by_client1, reason}

      {:tcp_error, ^client2, reason} ->
        :gen_tcp.close(client1)
        :gen_tcp.close(client2)
        {:tcp_error_by_client2, reason}

      {:tcp, ^client1, data} ->
        :gen_tcp.send(client2, data)
        send(parent_pid, {:bytes_sent, byte_size(data)})
        loop_tcp(parent_pid, client1, client2)

      {:tcp, ^client2, data} ->
        :gen_tcp.send(client1, data)
        send(parent_pid, {:bytes_sent, byte_size(data)})
        loop_tcp(parent_pid, client1, client2)
    end
  end

  def worker_udp(parent_pid, socket) do
    receive do
      :init -> :ok
    end

    :inet.setopts(socket, [{:active, true}])
    reason = loop_udp(parent_pid, socket, nil, nil, [])
    send(parent_pid, {:udp_down, reason})
  end

  defp loop_udp(parent_pid, socket, nil, nil, []) do
    receive do
      msg ->
        case msg do
          {:udp, _socket, peer_ip, peer_port, data} ->
            client = {peer_ip, peer_port}
            loop_udp(parent_pid, socket, client, nil, [data])
        end
    after
      35_000 ->
        :gen_udp.close(socket)
        :timeout_before_first_client
    end
  end

  defp loop_udp(parent_pid, socket, client1, nil, buffer) do
    receive do
      msg ->
        case msg do
          {:udp, _socket, peer_ip, peer_port, data} ->
            client = {peer_ip, peer_port}

            if client == client1 do
              loop_udp(parent_pid, socket, client1, nil, [data | buffer])
            else
              {host, port} = client1
              buffer = Enum.reverse([data | buffer])

              for packet <- buffer do
                :gen_udp.send(socket, host, port, packet)
                send(parent_pid, {:bytes_sent, byte_size(packet)})
              end

              loop_udp(parent_pid, socket, client1, client, [])
            end
        end
    after
      35_000 ->
        :gen_udp.close(socket)
        :timeout_before_second_client
    end
  end

  defp loop_udp(parent_pid, socket, {peer_ip_1, peer_port_1}, {peer_ip_2, peer_port_2}, []) do
    receive do
      msg ->
        case msg do
          {:udp, _socket, ^peer_ip_1, ^peer_port_1, data} ->
            :gen_udp.send(socket, peer_ip_2, peer_port_2, data)
            send(parent_pid, {:bytes_sent, byte_size(data)})
            loop_udp(parent_pid, socket, {peer_ip_1, peer_port_1}, {peer_ip_2, peer_port_2}, [])

          {:udp, _socket, ^peer_ip_2, ^peer_port_2, data} ->
            :gen_udp.send(socket, peer_ip_1, peer_port_1, data)
            send(parent_pid, {:bytes_sent, byte_size(data)})
            loop_udp(parent_pid, socket, {peer_ip_1, peer_port_1}, {peer_ip_2, peer_port_2}, [])

          {:udp, _socket, _peer_ip, _peer_port, _data} ->
            loop_udp(parent_pid, socket, {peer_ip_1, peer_port_1}, {peer_ip_2, peer_port_2}, [])
        end
    after
      3600_000 ->
        :gen_udp.close(socket)
        :timeout_no_traffic
    end
  end

  defp hex(binary) do
    DiodeClient.Base16.encode(binary)
  end
end
