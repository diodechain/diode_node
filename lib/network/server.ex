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

  alias DiodeClient.{Secp256k1, Wallet}
  use GenServer
  require Logger

  @type sslsocket() :: any()

  defstruct sockets: %{},
            clients: %{},
            protocol: nil,
            ports: [],
            opts: %{},
            pid: nil,
            acceptors: %{},
            self_conns: []

  @type t :: %Network.Server{
          sockets: %{integer() => sslsocket()},
          clients: map(),
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
  # @spec init({[integer()], atom(), %{}}) :: {:ok, Network.Server.t(), {:continue, :accept}}
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
    GenServer.call(name, :get_connections)
  end

  def ensure_node_connection(name, node_id, address, port)
      when node_id == nil or is_tuple(node_id) do
    GenServer.call(name, {:ensure_node_connection, node_id, address, port})
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

        clients =
          Enum.find(clients, nil, fn {_pid, key0} -> key0 == key end)
          |> case do
            nil -> clients
            {pid0, key0} -> Map.put(clients, key0, {pid0, System.os_time(:millisecond)})
          end

        {:noreply, %{state | clients: clients}}
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
      Enum.filter(state.clients, fn {_key, value} ->
        case value do
          {pid, _timestamp} -> is_pid(pid)
          _ -> false
        end
      end)
      |> Enum.map(fn {key, {pid, _timestamp}} -> {key, pid} end)
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

      case Map.get(state.clients, key) do
        {pid, _timestamp} ->
          {:reply, pid, state}

        _ ->
          worker = start_worker!(state, [:connect, node_id, address, port])

          clients =
            Map.put(state.clients, key, {worker, System.os_time(:millisecond)})
            |> Map.put(worker, key)

          {:reply, worker, %{state | clients: clients}}
      end
    end
  end

  def handle_call({:register, node_id}, {pid, _}, state) do
    if Wallet.equal?(Diode.wallet(), node_id) do
      state = %{state | self_conns: [pid | state.self_conns]}
      {:reply, {:ok, hd(state.ports)}, state}
    else
      register_node(node_id, pid, state)
    end
  end

  defp register_node(node_id, pid, state) do
    # Checking whether pid is already registered and remove for the update
    connect_key = Map.get(state.clients, pid)
    clients = Map.delete(state.clients, connect_key)
    actual_key = to_key(node_id)
    now = System.os_time(:millisecond)

    # Checking whether node_id is already registered
    clients =
      case Map.get(clients, actual_key) do
        nil ->
          # best case this is a new connection.
          Map.put(clients, actual_key, {pid, now})
          |> Map.put(pid, actual_key)

        {^pid, _timestamp} ->
          # also ok, this pid is already registered to this node_id
          Map.put(clients, pid, actual_key)

        {other_pid, _timestamp} ->
          # hm, another pid is given for the node_id logging this
          "#{state.protocol} Handshake anomaly(#{inspect(pid)}): #{Wallet.printable(node_id)} is already other_pid=#{inspect(other_pid)} connect_key=#{inspect(Base.encode16(connect_key))}"
          |> Logger.info()

          # If the actual key is the same as the "intended" key, then we can update the key
          # Otherwise we close the new connection as there is an existing connection already
          if actual_key == connect_key do
            Map.put(clients, actual_key, {pid, now})
            |> Map.put(pid, actual_key)
          else
            Process.exit(pid, :kill_clone)
            clients
          end
      end

    {:reply, {:ok, hd(state.ports)}, %{state | clients: clients}}
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
    case :ssl.transport_accept(state.sockets[port], 1000) do
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
