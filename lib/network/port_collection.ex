# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.PortCollection do
  alias DiodeClient.Base16

  @moduledoc """
    Port opening flow:

      Roles:
        Edge A - Remote TCP Client
        Client A - Local GenServer handling Edge A socket
        Client B - Local GenServer handling Edge B socket
        Edge B - Remote TCP Server

    1. Edge A send "portopen" via socket
    2. Client A receives "portopen" and calls PortCollection.request_portopen -- BLOCKING
    3. Client B receives cast: {:pccb_portopen, port, device_address}
    4. Client B send "portopen" via socket to Edge B
    5. Client B receives "ack" or "deny" from Edge B
    6. Client B calls PortCollection.confirm_portopen or PortCollection.deny_portopen
    7. Client A receives PortCollection.request_portopen response


    Port GenServers who are sender/receiver have to implement these calls:application

    - handle_cast({:pccb_portopen, port, device_address}, state)
    - handle_cast({:pccb_portsend, port, data}, state)
    - handle_cast({:pccb_portclose, port}, state)



    There are currently three access rights for "Ports" which are
    loosely following Posix conventions:
      1) r = Read
      2) w = Write
      3) s = Shared
  """
  defmodule PortClient do
    @enforce_keys [:ref]
    defstruct pid: nil, mon: nil, ref: nil, write: true, trace: false

    @type t :: %PortClient{
            pid: pid(),
            mon: reference(),
            ref: reference(),
            write: boolean(),
            trace: boolean()
          }
  end

  defmodule Port do
    defstruct state: nil,
              ref: nil,
              from: nil,
              clients: [],
              portname: nil,
              shared: false,
              mailbox: :queue.new(),
              trace: false

    @type ref :: binary()
    @type t :: %Port{
            state: :open | :pre_open,
            ref: ref(),
            from: nil | {pid(), reference()},
            clients: [PortClient.t()],
            portname: any(),
            shared: true | false,
            mailbox: :queue.queue(binary()),
            trace: boolean()
          }
  end

  alias Network.PortCollection
  @enforce_keys [:pid]
  defstruct pid: nil, refs: %{}
  @type t :: %PortCollection{pid: pid(), refs: %{Port.ref() => Port.t()}}

  @spec put(PortCollection.t(), Port.t()) :: PortCollection.t()
  def put(pc, port) do
    %{pc | refs: Map.put(pc.refs, port.ref, port)}
  end

  @spec delete(PortCollection.t(), Port.ref()) :: PortCollection.t()
  def delete(pc, ref) do
    %{pc | refs: Map.delete(pc.refs, ref)}
  end

  @spec get(PortCollection.t(), Port.ref(), any()) :: Port.t() | nil
  def get(pc, ref, default \\ nil) do
    Map.get(pc.refs, ref, default)
  end

  @spec get_clientref(PortCollection.t(), Port.ref()) :: {PortClient.t(), Port.t()} | nil
  def get_clientref(pc, cref) do
    Enum.find_value(pc.refs, fn {_ref, port} ->
      Enum.find_value(port.clients, fn
        client = %PortClient{ref: ^cref} -> {client, port}
        _ -> nil
      end)
    end)
  end

  @spec get_clientmon(PortCollection.t(), reference()) :: {PortClient.t(), Port.t()} | nil
  def get_clientmon(pc, cmon) do
    Enum.find_value(pc.refs, fn {_ref, port} ->
      Enum.find_value(port.clients, fn
        client = %PortClient{mon: ^cmon} -> {client, port}
        _ -> nil
      end)
    end)
  end

  @spec find_sharedport(PortCollection.t(), Port.t()) :: Port.t() | nil
  def find_sharedport(_pc, %Port{shared: false}) do
    nil
  end

  def find_sharedport(pc, %Port{portname: portname}) do
    Enum.find_value(pc.refs, fn
      {_ref, port = %Port{state: :open, portname: ^portname, shared: true}} -> port
      {_ref, _other} -> nil
    end)
  end

  def request_portopen(_device_address, _this, _portname, _flags, nil, _ref) do
    {:error, "not found"}
  end

  def request_portopen(device_address, this, portname, flags, pid, ref) do
    trace = if String.contains?(flags, "t"), do: this

    #  Receives an open request from another local connected edge worker.
    #  Now needs to forward the request to the device and remember to
    #  keep in 'pre-open' state until the device acks.
    # Todo: Check for network access based on contract
    resp =
      try do
        call(
          pid,
          {:portopen, this, ref, flags, portname, device_address},
          35_000
        )
      catch
        _kind, what ->
          case what do
            {:timeout, _} ->
              {:error, "timeout"}

            {{:timeout, _}, _} ->
              {:error, "timeout2"}

            {:no_activity_timeout, _} ->
              {:error, "no_activity_timeout"}

            {{:error, :einval}, _} ->
              {:error, "sudden close"}

            {:exit, :normal} ->
              {:error, "peer disconnect"}

            {:noproc, _} ->
              {:error, "peer already disconnected"}

            _ ->
              {:error, "unknown"}
          end
      end

    case resp do
      {:ok, cref} ->
        mon = monitor(this, pid)

        client = %PortClient{
          pid: pid,
          mon: mon,
          ref: cref,
          write: String.contains?(flags, "w"),
          trace: trace
        }

        port = %Port{state: :open, clients: [client], ref: ref, trace: trace}
        call(this, {:add_port, port})
        :ok

      {:error, reason} ->
        {:error, reason}

      :error ->
        {:error, "unexpected error"}
    end
  end

  def maybe_handle_info({:DOWN, mon, _type, _object, _info}, pc = %PortCollection{}) do
    case close(pc, get_clientmon(pc, mon)) do
      ^pc -> false
      pc2 -> pc2
    end
  end

  def maybe_handle_info({__MODULE__, cmd}, pc = %PortCollection{}) do
    handle_cast(cmd, pc)
  end

  def maybe_handle_info({{__MODULE__, req_id}, cmd}, pc = %PortCollection{}) do
    case handle_call(cmd, req_id, pc) do
      {:reply, ret, pc} ->
        send(req_id, {req_id, ret})
        pc

      {:noreply, pc} ->
        pc

      {:error, reason} ->
        # Debouncer.apply(
        #   self(),
        #   fn -> send(state.pid, {:check_activity, state.last_message}) end,
        #   15_000
        # )

        send(req_id, {req_id, {:error, reason}})
        pc
    end
  end

  def maybe_handle_info(_other, _pc) do
    false
  end

  defp handle_call({:monitor, pid}, _from, pc) do
    {:reply, Process.monitor(pid), pc}
  end

  defp handle_call({:add_port, port}, _from, pc) do
    {:reply, :ok, put(pc, port)}
  end

  @max_preopen_ports 5
  defp handle_call({:portopen, pid, ref, flags, portname, device_address}, from, pc) do
    trace = if String.contains?(flags, "t"), do: pid
    trace(trace, :state, "exec portopen #{Base16.encode(ref)}")

    preopen_count =
      Enum.count(pc.refs, fn {_key, %Port{state: pstate}} -> pstate == :pre_open end)

    cond do
      preopen_count > @max_preopen_ports ->
        {:error, "too many hanging ports"}

      PortCollection.get(pc, ref) != nil ->
        {:error, "already opening"}

      true ->
        mon = monitor(pc.pid, pid)

        client = %PortClient{
          mon: mon,
          pid: pid,
          ref: make_ref(),
          write: String.contains?(flags, "r"),
          trace: trace
        }

        port = %Port{
          state: :pre_open,
          from: from,
          clients: [client],
          portname: portname,
          shared: String.contains?(flags, "s"),
          trace: trace,
          ref: ref
        }

        case PortCollection.find_sharedport(pc, port) do
          nil ->
            pc = PortCollection.put(pc, port)
            GenServer.cast(self(), {:pccb_portopen, port, device_address})
            {:noreply, pc}

          existing_port ->
            port = %Port{existing_port | clients: [client | existing_port.clients]}
            pc = PortCollection.put(pc, port)
            {:reply, {:ok, client.ref}, pc}
        end
    end
  end

  defp handle_cast({:portclose, client_ref}, pc) do
    close(pc, get_clientref(pc, client_ref))
  end

  defp handle_cast({:portsend, client_ref, data}, pc) do
    with {_client, port} <- get_clientref(pc, client_ref) do
      GenServer.cast(self(), {:pccb_portsend, port, data})
    end

    pc
  end

  defp close(pc, tuple) do
    case tuple do
      nil ->
        pc

      {client, %Port{clients: [client], ref: ref} = port} ->
        Process.demonitor(client.mon, [:flush])
        GenServer.cast(self(), {:pccb_portclose, port})
        PortCollection.delete(pc, ref)

      {client, %Port{clients: more} = port} ->
        Process.demonitor(client.mon, [:flush])
        put(pc, %Port{port | clients: List.delete(more, client)})
    end
  end

  def confirm_portopen(pc, ref) do
    case PortCollection.get(pc, ref) do
      nil ->
        {:error, "port does not exist"}

      port = %Port{state: :pre_open, from: from, clients: [client]} ->
        send(from, {from, {:ok, client.ref}})
        pc = PortCollection.put(pc, %Port{port | state: :open, from: nil})
        {:ok, pc}
    end
  end

  def deny_portopen(pc, ref, reason) do
    port = %Port{state: :pre_open} = PortCollection.get(pc, ref)
    send(port.from, {port.from, {:error, reason}})
    {:ok, do_portclose(pc, port)}
  end

  def portclose(pc, ref) when is_binary(ref) do
    case PortCollection.get(pc, ref) do
      nil ->
        {:error, "port does not exit"}

      port = %Port{state: :open} ->
        {:ok, do_portclose(pc, port)}
    end
  end

  defp do_portclose(pc, port = %Port{}) do
    for client <- port.clients do
      cast(client.pid, {:portclose, client.ref})
      Process.demonitor(client.mon, [:flush])
    end

    delete(pc, port.ref)
  end

  def portsend(pc, ref, data) do
    case PortCollection.get(pc, ref) do
      nil ->
        {:error, "port does not exist"}

      %Port{state: :open, clients: clients, trace: trace} ->
        trace(trace, :state, "recv portsend from #{Base16.encode(ref)}")

        for client <- clients do
          if client.write do
            cast(client.pid, {:portsend, client.ref, data})
          end
        end

        :ok
    end
  end

  defp monitor(this, pid) do
    if self() == this do
      Process.monitor(pid)
    else
      call(this, {:monitor, pid}, :infinity)
    end
  end

  defp call(pid, cmd, timeout \\ 5000) do
    ref = Process.monitor(pid)
    req_id = :erlang.alias([:reply])
    send(pid, {{__MODULE__, req_id}, cmd})

    receive do
      {^req_id, reply} ->
        Process.demonitor(ref, [:flush])
        reply

      {:DOWN, ^ref, :process, _pid, reason} ->
        throw({:error, reason})
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        throw({:error, :timeout})
    end
  end

  defp cast(pid, cmd) do
    send(pid, {__MODULE__, cmd})
  end

  defp trace(nil, _state, _format), do: :nop

  defp trace(trace, state, format) do
    msg = [System.os_time(:millisecond), state, format]
    GenServer.cast(trace, {:trace, msg})
  end
end
