# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.Server do
  @moduledoc """
    General TLS 1.2 socket server that ensures:
      * Secp256k1 handshakes
      * Identities on server and client
      * Self-signed certs on both of them

    Then it spawns client connection based on the protocol handler
  """

  alias DiodeClient.{Base16, Secp256k1, Wallet}
  use GenServer
  require Logger

  @type sslsocket() :: any()

  defstruct sockets: %{},
            clients: %{},
            ready: %{},
            protocol: nil,
            ports: [],
            opts: %{},
            pid: nil,
            acceptors: %{},
            self_conns: []

  @type t :: %Network.Server{
          sockets: %{integer() => sslsocket()},
          clients: map(),
          ready: %{binary() => pid()},
          protocol: atom(),
          ports: [integer()],
          opts: %{},
          acceptors: %{integer() => pid()},
          pid: pid(),
          self_conns: []
        }

  def start_link({port, protocolHandler, opts}) do
    GenServer.start_link(__MODULE__, {port, protocolHandler, opts}, name: opts.name)
  end

  def child(ports, protocolHandler, opts \\ []) do
    opts =
      %{name: protocolHandler}
      |> Map.merge(Map.new(opts))

    Supervisor.child_spec({__MODULE__, {List.wrap(ports), protocolHandler, opts}}, id: opts.name)
  end

  @impl true
  #
  def init({ports, protocolHandler, opts}) when is_list(ports) do
    :erlang.process_flag(:trap_exit, true)

    {ports, sockets} =
      Enum.reduce(ports, {[], %{}}, fn port, {ports, sockets} ->
        case :ssl.listen(port, protocolHandler.ssl_options([]) ++ [ip: Diode.any_ip()]) do
          {:ok, socket} ->
            {ports ++ [port], Map.put(sockets, port, socket)}

          {:error, reason} ->
            Logger.error(
              "Failed to open #{inspect(protocolHandler)} port: #{inspect(port)} for reason: #{inspect(reason)}"
            )

            {ports, sockets}
        end
      end)

    {:ok,
     %Network.Server{
       sockets: sockets,
       protocol: protocolHandler,
       ports: ports,
       opts: opts,
       pid: self()
     }, {:continue, :accept}}
  end

  def check(_cert, event, state) do
    case event do
      {:bad_cert, :selfsigned_peer} ->
        {:valid, state}

      {:bad_cert, :cert_expired} ->
        {:valid, state}

      other ->
        Logger.warning("Check cert failed for #{inspect(other)}")
        {:fail, event}
    end
  end

  def get_connections(name) do
    if pid = Process.whereis(name) do
      GenServerDbg.call(pid, :get_connections)
    else
      %{}
    end
  end

  @doc """
  Peers that finished handshake and can accept `{:rpc, _}` (logical Kademlia network).
  """
  def get_ready_connections(name) do
    if pid = Process.whereis(name) do
      GenServerDbg.call(pid, :get_ready_connections)
    else
      %{}
    end
  end

  def ensure_node_connection(name, node_id, address, port)
      when node_id == nil or is_tuple(node_id) do
    GenServerDbg.call(name, {:ensure_node_connection, node_id, address, port})
  end

  def handle_client_exit(state = %{clients: clients}, pid, reason) do
    if reason not in [:normal, {:error, :closed}] do
      Logger.warning("#{inspect(state.protocol)} Connection failed (#{inspect({pid, reason})})")
    end

    case Map.get(clients, pid) do
      nil ->
        {:noreply, state}

      key ->
        clients = Map.drop(clients, [pid, key])
        ready = Map.delete(state.ready, key)

        clients =
          Enum.find(clients, nil, fn {_entry, key0} -> key0 == key end)
          |> case do
            nil -> clients
            {pid0, key0} -> Map.put(clients, key0, client_entry(pid0))
          end

        {:noreply, %{state | clients: clients, ready: ready}}
    end
  end

  def handle_acceptor_exit(state = %{acceptors: acceptors}, port, pid, reason) do
    Logger.error("#{state.protocol} acceptor crashed: #{inspect(reason)}")

    acceptors =
      Map.delete(acceptors, pid)
      |> Map.put(spawn_link(fn -> do_accept(state, port) end), port)

    {:noreply, %{state | acceptors: acceptors}}
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, state = %{acceptors: acceptors}) do
    port = acceptors[pid]

    if port do
      handle_acceptor_exit(state, port, pid, reason)
    else
      handle_client_exit(state, pid, reason)
    end
  end

  def handle_info(msg, state) do
    Logger.warning("#{state.protocol} unhandled info: #{inspect(msg)}")
    {:noreply, state}
  end

  defp to_key(nil) do
    Wallet.new() |> Wallet.address!()
  end

  defp to_key(wallet) do
    Wallet.address!(wallet)
  end

  @impl true
  def handle_call(:get_connections, _from, state) do
    result =
      state.clients
      |> Enum.filter(fn {_key, value} -> client_entry?(value) end)
      |> Enum.map(fn {key, value} -> {key, client_pid(value)} end)
      |> Map.new()

    {:reply, result, state}
  end

  def handle_call(:get_ready_connections, _from, state) do
    result =
      state.ready
      |> Enum.filter(fn {address, pid} ->
        entry = Map.get(state.clients, address)
        client_entry?(entry) and client_pid(entry) == pid and Process.alive?(pid)
      end)
      |> Map.new()

    {:reply, result, state}
  end

  def handle_call({:ensure_node_connection, node_id, address, port}, _from, state)
      when node_id == nil or is_tuple(node_id) do
    if Wallet.equal?(Diode.wallet(), node_id) do
      client = Enum.find(state.self_conns, fn pid -> Process.alive?(pid) end)

      if client != nil do
        {:reply, client, state}
      else
        worker = start_worker!(state, [:connect, node_id, "localhost", Diode.peer2_port()])
        {:reply, worker, %{state | self_conns: [worker]}}
      end
    else
      key = to_key(node_id)

      case lookup_client_pid(state.clients, key) do
        pid when is_pid(pid) ->
          {:reply, pid, state}

        nil ->
          worker = start_worker!(state, [:connect, node_id, address, port])

          clients =
            Map.put(state.clients, key, client_entry(worker, address, port))
            |> Map.put(worker, key)

          {:reply, worker, %{state | clients: clients}}
      end
    end
  end

  # compatibility with old code during live update
  def handle_call({:register, node_id}, from, state) do
    handle_call({:register, node_id, nil, nil}, from, state)
  end

  def handle_call({:register, node_id, address, port}, {pid, _}, state) do
    if Wallet.equal?(Diode.wallet(), node_id) do
      state = %{state | self_conns: [pid | state.self_conns]}
      {:reply, {:ok, hd(state.ports)}, state}
    else
      register_node(node_id, address, port, pid, state)
    end
  end

  def handle_call({:mark_ready, address, pid}, _from, state) do
    {:reply, :ok, %{state | ready: mark_ready(state.ready, state.clients, address, pid)}}
  end

  @impl true
  def handle_cast({:mark_ready, address, pid}, state) do
    {:noreply, %{state | ready: mark_ready(state.ready, state.clients, address, pid)}}
  end

  defp mark_ready(ready, clients, address, pid) do
    case Map.get(clients, address) do
      nil ->
        ready

      entry ->
        if client_entry?(entry) and client_pid(entry) == pid do
          Map.put(ready, address, pid)
        else
          ready
        end
    end
  end

  defp register_node(node_id, address, port, pid, state) do
    # Checking whether pid is already registered and remove for the update
    connect_key = Map.get(state.clients, pid)

    clients =
      state.clients
      |> Map.delete(pid)
      |> then(fn c -> if connect_key, do: Map.delete(c, connect_key), else: c end)

    actual_key = to_key(node_id)
    now = System.os_time(:millisecond)

    # Checking whether node_id is already registered
    clients =
      case Map.get(clients, actual_key) do
        nil ->
          put_client(clients, actual_key, pid, address, port, now)

        entry ->
          cond do
            not client_entry?(entry) ->
              put_client(clients, actual_key, pid, address, port, now)

            client_pid(entry) == pid ->
              put_client(clients, actual_key, pid, address, port, now)

            true ->
              resolve_client_conflict(
                clients,
                actual_key,
                pid,
                address,
                port,
                now,
                connect_key,
                entry,
                state
              )
          end
      end

    {:reply, {:ok, hd(state.ports)}, %{state | clients: clients}}
  end

  defp resolve_client_conflict(
         clients,
         actual_key,
         pid,
         address,
         port,
         now,
         connect_key,
         other_entry,
         state
       ) do
    other_pid = client_pid(other_entry)

    other_peer =
      case other_entry do
        {_, _, addr, port} when not is_nil(addr) ->
          Network.Handler.format_endpoint({addr, port}) || "unknown"

        _ ->
          "unknown"
      end

    connect_key_str =
      if connect_key, do: Base16.encode(connect_key), else: "nil"

    address_str = if is_tuple(address), do: :inet.ntoa(address), else: inspect(address)

    "#{inspect(state.protocol)} Handshake anomaly(#{inspect(pid)}): address=#{address_str}, port=#{port} is already connected to other_pid=#{inspect(other_pid)} other_peer=#{other_peer} connect_key=#{connect_key_str}"
    |> Logger.info()

    cond do
      actual_key == connect_key ->
        kill_clone(other_pid, actual_key)
        put_client(clients, actual_key, pid, address, port, now)

      is_nil(connect_key) ->
        kill_clone(other_pid, actual_key)
        put_client(clients, actual_key, pid, address, port, now)

      state.protocol == Network.EdgeV2 ->
        put_client(clients, actual_key, pid, address, port, now)

      true ->
        kill_clone(pid, actual_key)
        Map.delete(clients, pid)
    end
  end

  defp put_client(clients, key, pid, address, port, now) do
    clients
    |> Map.put(key, client_entry(pid, address, port, now))
    |> Map.put(pid, key)
  end

  defp lookup_client_pid(clients, key) do
    case Map.get(clients, key) do
      entry when not is_nil(entry) ->
        if client_entry?(entry),
          do: client_pid(entry),
          else: find_dialing_client_pid(clients, key)

      nil ->
        find_dialing_client_pid(clients, key)
    end
  end

  defp find_dialing_client_pid(clients, key) do
    Enum.find_value(clients, fn
      {pid, ^key} when is_pid(pid) -> pid
      _ -> nil
    end)
  end

  defp client_entry(pid, peer_addr \\ nil, peer_port \\ nil, now \\ nil) do
    {pid, now || System.os_time(:millisecond), peer_addr, peer_port}
  end

  defp client_entry?(entry) when is_tuple(entry) do
    tuple_size(entry) in [2, 4] and is_pid(elem(entry, 0))
  end

  defp client_entry?(_), do: false

  defp client_pid(entry) when is_tuple(entry) and tuple_size(entry) in [2, 4] do
    elem(entry, 0)
  end

  defp kill_clone(pid, actual_key) do
    if Wallet.equal?(Diode.wallet(), actual_key) do
      # Don't kill the self-connection (it always registers twice)
      :ok
    else
      Process.exit(pid, :kill_clone)
    end
  end

  @impl true
  def handle_continue(:accept, state = %{ports: ports}) do
    acceptors =
      Enum.reduce(ports, %{}, fn port, acceptors ->
        Map.put(acceptors, spawn_link(fn -> do_accept(state, port) end), port)
      end)

    {:noreply, %{state | acceptors: acceptors}}
  end

  defp do_accept(state, port) do
    case :ssl.transport_accept(state.sockets[port], 5000) do
      {:error, :timeout} ->
        :ok

      {:error, :closed} ->
        # Connection abort before handshake
        Logger.info("#{state.protocol} Anomaly - Connection closed before TLS handshake")

      {:ok, newSocket} ->
        spawn_link(fn ->
          peername = :ssl.peername(newSocket)

          with {:ok, {_address, _port}} <- peername,
               {:ok, newSocket2} <- :ssl.handshake(newSocket, 45000) do
            worker = start_worker!(state, :init)
            :ok = :ssl.controlling_process(newSocket2, worker)
            send(worker, {:init, newSocket2})
          else
            {:error, error} ->
              Logger.warning(
                "#{state.protocol} Handshake error: #{inspect(error)} #{inspect(peername)}"
              )
          end
        end)
    end

    do_accept(state, port)
  end

  defp start_worker!(state, cmd) do
    worker_state = %{
      server_pid: state.pid
    }

    {:ok, worker} =
      GenServer.start(state.protocol, {worker_state, cmd},
        hibernate_after: 5_000,
        timeout: 4_000
      )

    worker
  end

  def default_ssl_options(opts) do
    # Can be :server or :client
    role = Keyword.get(opts, :role, :server)

    w = Diode.wallet()
    public = Wallet.pubkey_long!(w)
    private = Wallet.privkey!(w)
    cert = Secp256k1.selfsigned(private, public)

    [
      active: false,
      cacerts: [cert],
      cert: cert,
      delay_send: true,
      eccs: [:secp256k1],
      key: {:ECPrivateKey, Secp256k1.der_encode_private(private, public)},
      log_alert: false,
      log_level: :warning,
      mode: :binary,
      nodelay: false,
      packet: 2,
      reuse_sessions: true,
      reuseaddr: true,
      send_timeout_close: true,
      send_timeout: 30_000,
      show_econnreset: true,
      verify_fun: {&check/3, nil},
      verify: :verify_peer,
      versions: [:"tlsv1.2"]
    ] ++
      if role == :server do
        [fail_if_no_peer_cert: true]
      else
        []
      end
  end
end
