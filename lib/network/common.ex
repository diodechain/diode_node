# Diode Server
# Copyright 2021-2025 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.Common do
  @moduledoc """
  Shared TLS, connection registry, and handler handshake helpers for
  `Network.EdgeServer`, `Network.PeerServer`, `Network.EdgeV2`, and
  `Network.PeerHandlerV2`.

  Handshake re-registration calls `register_node_clients/6`, which passes
  `connect_key` and `actual_key` to each server's `conflict_resolver`. Edge and
  peer registries diverge when those keys differ or `connect_key` is `nil`; see
  `Network.EdgeServer` and `Network.PeerServer`.
  """

  alias DiodeClient.{Base16, Certs, Secp256k1, Wallet}
  require Logger

  @type conflict_resolver ::
          (map(), binary(), pid(), term(), term(), integer(), binary() | nil, tuple() -> map())

  @type handshake_callbacks :: %{
          do_init: (map() -> {:noreply, map()}),
          on_nodeid: (term() -> :ok)
        }

  defmacro __using__(opts \\ []) do
    case Keyword.pop(opts, :server) do
      {server_opts, []} when is_list(server_opts) ->
        server_using(server_opts)

      {nil, _} ->
        handler_using()
    end
  end

  defp handler_using do
    quote location: :keep do
      def init({state, :init}) do
        Network.Common.init_handler(state, :init)
      end

      def init({state, [:connect, node_id, address, port]}) do
        Network.Common.init_handler(state, [:connect, node_id, address, port])
      end

      def handle_continue(:init, state) do
        Network.Common.handle_continue_init(state, __MODULE__, handshake_callbacks())
      end

      def handle_continue([:connect, node_id, address, port], state) do
        Network.Common.handle_continue_connect(
          state,
          __MODULE__,
          node_id,
          address,
          port,
          handshake_callbacks()
        )
      end

      defp handshake_callbacks do
        %{do_init: &do_init/1, on_nodeid: &on_nodeid/1}
      end
    end
  end

  defp server_using(server_opts) do
    handler = Keyword.fetch!(server_opts, :handler)
    name = Keyword.fetch!(server_opts, :name)

    conflict_resolver =
      case Keyword.fetch!(server_opts, :conflict) do
        :edge ->
          quote do
            &Network.Common.resolve_edge_conflict(
              unquote(handler),
              &1,
              &2,
              &3,
              &4,
              &5,
              &6,
              &7,
              &8
            )
          end

        :peer ->
          quote do
            &Network.Common.resolve_peer_conflict(
              unquote(handler),
              &1,
              &2,
              &3,
              &4,
              &5,
              &6,
              &7,
              &8
            )
          end

        other ->
          raise ArgumentError,
                "use Network.Common, server: [...] conflict: must be :edge or :peer, got: #{inspect(other)}"
      end

    quote location: :keep do
      @handler unquote(handler)
      @name unquote(name)

      def child(ports, opts \\ []) do
        Network.Common.server_child(__MODULE__, unquote(name), ports, opts)
      end

      def start_link({ports, opts}) do
        Network.Common.server_start_link(__MODULE__, unquote(name), {ports, opts})
      end

      def get_connections(name \\ unquote(name)) do
        Network.Common.server_get_connections(name)
      end

      def init({ports, opts}) do
        Network.Common.server_init(__MODULE__, unquote(handler), ports, opts)
      end

      def handle_continue(:accept, state) do
        Network.Common.server_handle_continue_accept(state, @handler)
      end

      def handle_call(:get_connections, from, state) do
        Network.Common.server_handle_call_get_connections(from, state)
      end

      def handle_call({:register, node_id}, from, state) do
        Network.Common.server_handle_call_register(
          {:register, node_id, nil, nil},
          from,
          state,
          unquote(conflict_resolver)
        )
      end

      def handle_call({:register, node_id, address, port}, from, state) do
        Network.Common.server_handle_call_register(
          {:register, node_id, address, port},
          from,
          state,
          unquote(conflict_resolver)
        )
      end

      def handle_info({:EXIT, pid, reason}, state) do
        Network.Common.server_handle_info_exit(state, @handler, pid, reason)
      end

      def handle_info(msg, state) do
        Network.Common.server_handle_info_unhandled(@handler, msg, state)
      end
    end
  end

  # --- TLS connection registry (EdgeServer / PeerServer) ---

  def server_child(module, default_name, ports, opts) do
    opts = %{name: default_name} |> Map.merge(Map.new(opts))
    Supervisor.child_spec({module, {List.wrap(ports), opts}}, id: default_name)
  end

  def server_start_link(module, default_name, {ports, opts}) do
    GenServer.start_link(module, {ports, opts}, name: opts[:name] || opts.name || default_name)
  end

  def server_get_connections(name) do
    if pid = Process.whereis(name) do
      GenServerDbg.call(pid, :get_connections)
    else
      %{}
    end
  end

  def server_init(module, handler_module, ports, opts) do
    :erlang.process_flag(:trap_exit, true)
    {ports, sockets} = init_listen(ports, handler_module)

    {:ok,
     struct(module, %{
       sockets: sockets,
       ports: ports,
       opts: opts,
       pid: self()
     }), {:continue, :accept}}
  end

  def server_handle_continue_accept(state, handler_module) do
    acceptors =
      spawn_acceptors(state.ports, fn port ->
        do_accept(state, handler_module, port)
      end)

    {:noreply, %{state | acceptors: acceptors}}
  end

  def server_handle_call_get_connections(_from, state) do
    {:reply, get_connections_from_state(state.clients), state}
  end

  def server_handle_call_register(
        {:register, node_id, address, port},
        {pid, _},
        state,
        conflict_resolver
      ) do
    if Wallet.equal?(Diode.wallet(), node_id) do
      {:reply, {:ok, hd(state.ports)}, %{state | self_conns: [pid | state.self_conns]}}
    else
      clients =
        register_node_clients(
          state.clients,
          node_id,
          address,
          port,
          pid,
          conflict_resolver
        )

      {:reply, {:ok, hd(state.ports)}, %{state | clients: clients}}
    end
  end

  def server_handle_info_exit(state, handler_module, pid, reason) do
    case state.acceptors[pid] do
      nil ->
        handle_client_exit_noreply(state, pid, reason, inspect(handler_module))

      port ->
        Logger.error("#{inspect(handler_module)} acceptor crashed: #{inspect(reason)}")

        acceptors =
          state.acceptors
          |> Map.delete(pid)
          |> Map.put(
            spawn_link(fn -> do_accept(state, handler_module, port) end),
            port
          )

        {:noreply, %{state | acceptors: acceptors}}
    end
  end

  def server_handle_info_unhandled(handler_module, msg, state) do
    Logger.warning("#{inspect(handler_module)} unhandled info: #{inspect(msg)}")
    {:noreply, state}
  end

  def resolve_edge_conflict(
        handler_module,
        clients,
        actual_key,
        pid,
        address,
        port,
        now,
        connect_key,
        other_entry
      ) do
    other_pid = client_pid(other_entry)

    conflict_log(inspect(handler_module),
      pid: pid,
      address: address,
      port: port,
      other_pid: other_pid,
      other_entry: other_entry,
      connect_key: connect_key
    )

    if actual_key == connect_key do
      kill_clone(other_pid, actual_key)
      put_client(clients, actual_key, pid, address, port, now)
    else
      put_client(clients, actual_key, pid, address, port, now)
    end
  end

  def resolve_peer_conflict(
        handler_module,
        clients,
        actual_key,
        pid,
        address,
        port,
        now,
        connect_key,
        other_entry
      ) do
    other_pid = client_pid(other_entry)

    conflict_log(inspect(handler_module),
      pid: pid,
      address: address,
      port: port,
      other_pid: other_pid,
      other_entry: other_entry,
      connect_key: connect_key
    )

    cond do
      actual_key == connect_key or is_nil(connect_key) ->
        kill_clone(other_pid, actual_key)
        put_client(clients, actual_key, pid, address, port, now)

      true ->
        kill_clone(pid, actual_key)
        Map.delete(clients, pid)
    end
  end

  # --- Handler process setup ---

  def init_handler(state, continue) do
    setup_process(state)
    {:ok, state, {:continue, continue}}
  end

  def handle_continue_init(state, handler_module, callbacks) do
    socket =
      receive do
        {:init, socket} -> socket
      after
        5000 ->
          log(handler_module, nil, "Socket continue timeout")
          {:stop, :normal, state}
      end

    enter_loop(Map.put(state, :socket, socket), handler_module, callbacks)
  end

  def handle_continue_connect(state, handler_module, node_id, address, port, callbacks) do
    connect_outbound(state, handler_module, node_id, address, port, callbacks)
  end

  def enter_loop(state, handler_module, callbacks) do
    connect_handshake(state, handler_module, callbacks)
  end

  def setup_process(state) do
    Process.link(state.server_pid)
    Process.flag(:max_heap_size, 25_000_000)
  end

  def connect_handshake(state, handler_module, callbacks) do
    %{socket: socket, server_pid: server} = state

    with {:ok, _info} <- :ssl.connection_information(socket),
         {:ok, {address, port}} <- :ssl.peername(socket),
         {:ok, cert} <- :ssl.peercert(socket),
         remote_id <- Wallet.from_pubkey(Certs.id_from_der(cert)),
         {:ok, server_port} <-
           GenServerDbg.call(server, {:register, remote_id, address, port}),
         :ok <- set_keepalive(:os.type(), socket),
         :ok <- :ssl.setopts(socket, active: true) do
      expected_id = state[:node_id]

      if expected_id != nil and not Wallet.equal?(expected_id, remote_id) do
        log(
          handler_module,
          state,
          "Expected #{Wallet.printable(expected_id)} different from found #{Wallet.printable(remote_id)}"
        )

        callbacks.on_nodeid.(expected_id)
      end

      callbacks.on_nodeid.(remote_id)

      state =
        Map.merge(state, %{
          socket: socket,
          node_id: remote_id,
          node_address: address,
          node_port: port,
          server_port: server_port
        })

      callbacks.do_init.(state)
    else
      {:error, reason} ->
        log(handler_module, nil, "Connection gone away #{inspect(reason)}")
        {:stop, :normal, state}
    end
  end

  def connect_outbound(state, handler_module, node_id, address, port, callbacks) do
    address =
      case address do
        bin when is_binary(bin) -> :erlang.binary_to_list(address)
        tup when is_tuple(tup) -> tup
      end

    case :ssl.connect(address, port, handler_module.ssl_options(role: :client), 5000) do
      {:ok, socket} ->
        connect_handshake(
          Map.merge(state, %{socket: socket, address: address, node_id: node_id}),
          handler_module,
          callbacks
        )

      {:error, :timeout} ->
        callbacks.on_nodeid.(node_id)
        {:stop, :timeout, state}

      other ->
        callbacks.on_nodeid.(node_id)

        log(
          handler_module,
          {node_id, address, port},
          "Connection failed in ssl.connect(): #{inspect(other)}"
        )

        {:stop, :normal, state}
    end
  end

  def set_keepalive({:unix, :linux}, socket) do
    sol_socket = 1
    so_keepalive = 9
    ipproto_tcp = 6
    tcp_keepcnt = 6
    tcp_keepidle = 4
    tcp_keepintvl = 5

    with :ok <- set_tcpopt(socket, sol_socket, so_keepalive, 1),
         :ok <- set_tcpopt(socket, ipproto_tcp, tcp_keepcnt, 5),
         :ok <- set_tcpopt(socket, ipproto_tcp, tcp_keepidle, 60),
         :ok <- set_tcpopt(socket, ipproto_tcp, tcp_keepintvl, 60) do
      :ok
    end
  end

  def set_keepalive(_other, socket) do
    :ssl.setopts(socket, [{:keepalive, true}])
  end

  def set_tcpopt(socket, level, opt, value) do
    :ssl.setopts(socket, [{:raw, level, opt, <<value::unsigned-little-size(32)>>}])
  end

  # --- Logging ---

  def log(handler_module, state, string) do
    mod = handler_module |> Module.split() |> List.last()
    Logger.info("#{mod} #{name(state)}: #{string}")
  end

  def name(%{node_id: node_id, node_address: node_address})
      when node_address != nil do
    name({node_id, node_address})
  end

  def name(%{node_id: node_id, node_address: node_address}) do
    name({node_id, node_address})
  end

  def name(%{server_pid: _pid}), do: "pre_connection_information"

  def name({node_id, node_address, port}) do
    "#{name({node_id, node_address})}:#{port}"
  end

  def name({node_id, node_address}) do
    prefix =
      case node_id do
        bin when is_binary(bin) -> Base16.encode(node_id) <> "@"
        wallet when is_tuple(wallet) -> Base16.encode(Wallet.address!(wallet)) <> "@"
        _ -> ""
      end

    prefix <>
      case node_address do
        tuple when is_tuple(tuple) -> List.to_string(:inet.ntoa(tuple))
        bin when is_binary(bin) -> bin
        list when is_list(list) -> List.to_string(list)
        other -> inspect(other)
      end
  end

  def name(nil), do: "nil"

  def format_endpoint({addr, port}) when not is_nil(addr) and is_integer(port) do
    "#{format_inet_address(addr)}:#{port}"
  end

  def format_endpoint({addr, _}) when not is_nil(addr), do: format_inet_address(addr)
  def format_endpoint(_), do: nil

  def format_peer_endpoint(pid) when is_pid(pid) do
    case peer_endpoint(pid) do
      endpoint when is_tuple(endpoint) ->
        format_endpoint(endpoint) || if(Process.alive?(pid), do: "unknown", else: "dead")

      nil ->
        if Process.alive?(pid), do: "unknown", else: "dead"
    end
  end

  def format_peer_endpoint(_), do: "unknown"

  def peer_endpoint(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        case :sys.get_state(pid) do
          %{node_address: addr, node_port: port} when not is_nil(addr) -> {addr, port}
          %{node_address: addr} when not is_nil(addr) -> {addr, nil}
          _ -> nil
        end
      catch
        :exit, _ -> nil
      end
    else
      nil
    end
  end

  def peer_endpoint(_), do: nil

  defp format_inet_address(addr) when is_tuple(addr), do: :inet.ntoa(addr) |> List.to_string()
  defp format_inet_address(addr) when is_list(addr), do: List.to_string(addr)
  defp format_inet_address(addr) when is_binary(addr), do: addr
  defp format_inet_address(addr), do: inspect(addr)

  # --- TLS ---

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

  def default_ssl_options(opts) do
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

  def init_listen(ports, handler_module) do
    Enum.reduce(ports, {[], %{}}, fn port, {ports, sockets} ->
      case :ssl.listen(port, handler_module.ssl_options([]) ++ [ip: Diode.any_ip()]) do
        {:ok, socket} ->
          {ports ++ [port], Map.put(sockets, port, socket)}

        {:error, reason} ->
          Logger.error(
            "Failed to open #{inspect(handler_module)} port: #{inspect(port)} for reason: #{inspect(reason)}"
          )

          {ports, sockets}
      end
    end)
  end

  def spawn_acceptors(ports, acceptor_fun) do
    Enum.reduce(ports, %{}, fn port, acceptors ->
      Map.put(acceptors, spawn_link(fn -> acceptor_fun.(port) end), port)
    end)
  end

  def do_accept(state, handler_module, port) do
    case :ssl.transport_accept(state.sockets[port], 5000) do
      {:error, :timeout} ->
        :ok

      {:error, :closed} ->
        Logger.info("#{inspect(handler_module)} Anomaly - Connection closed before TLS handshake")

      {:ok, new_socket} ->
        spawn_link(fn ->
          peername = :ssl.peername(new_socket)

          with {:ok, {_address, _port}} <- peername,
               {:ok, new_socket2} <- :ssl.handshake(new_socket, 45_000) do
            worker = start_worker!(state, handler_module, :init)
            :ok = :ssl.controlling_process(new_socket2, worker)
            send(worker, {:init, new_socket2})
          else
            {:error, error} ->
              Logger.warning(
                "#{inspect(handler_module)} Handshake error: #{inspect(error)} #{inspect(peername)}"
              )
          end
        end)
    end

    do_accept(state, handler_module, port)
  end

  def start_worker!(state, handler_module, cmd) do
    worker_state = %{server_pid: state.pid}

    {:ok, worker} =
      GenServer.start(handler_module, {worker_state, cmd},
        hibernate_after: 5_000,
        timeout: 4_000
      )

    worker
  end

  # --- Registry ---

  def to_key(nil), do: Wallet.new() |> Wallet.address!()
  def to_key(wallet), do: Wallet.address!(wallet)

  def client_entry(pid, peer_addr \\ nil, peer_port \\ nil, now \\ nil) do
    {pid, now || System.os_time(:millisecond), peer_addr, peer_port}
  end

  def client_entry?(entry) when is_tuple(entry) do
    tuple_size(entry) in [2, 4] and is_pid(elem(entry, 0))
  end

  def client_entry?(_), do: false

  def client_pid(entry) when is_tuple(entry) and tuple_size(entry) in [2, 4], do: elem(entry, 0)

  def put_client(clients, key, pid, address, port, now) do
    clients
    |> Map.put(key, client_entry(pid, address, port, now))
    |> Map.put(pid, key)
  end

  def lookup_client_pid(clients, key) do
    case Map.get(clients, key) do
      entry when not is_nil(entry) ->
        if client_entry?(entry),
          do: client_pid(entry),
          else: find_dialing_client_pid(clients, key)

      nil ->
        find_dialing_client_pid(clients, key)
    end
  end

  def find_dialing_client_pid(clients, key) do
    Enum.find_value(clients, fn
      {pid, ^key} when is_pid(pid) -> pid
      _ -> nil
    end)
  end

  def kill_clone(pid, actual_key) do
    if Wallet.equal?(Diode.wallet(), actual_key) do
      :ok
    else
      Process.exit(pid, :kill_clone)
    end
  end

  def conflict_log(label, opts) do
    pid = Keyword.fetch!(opts, :pid)
    address = Keyword.fetch!(opts, :address)
    port = Keyword.fetch!(opts, :port)
    other_pid = Keyword.fetch!(opts, :other_pid)
    other_entry = Keyword.fetch!(opts, :other_entry)
    connect_key = Keyword.fetch!(opts, :connect_key)

    other_peer =
      case other_entry do
        {_, _, addr, p} when not is_nil(addr) -> format_endpoint({addr, p}) || "unknown"
        _ -> "unknown"
      end

    connect_key_str = if connect_key, do: Base16.encode(connect_key), else: "nil"

    address_str = if is_tuple(address), do: :inet.ntoa(address), else: inspect(address)

    Logger.info(
      "#{label} Handshake anomaly(#{inspect(pid)}): address=#{address_str}, port=#{port} is already connected to other_pid=#{inspect(other_pid)} other_peer=#{other_peer} connect_key=#{connect_key_str}"
    )
  end

  @doc """
  Registers `node_id` for `pid`, invoking `conflict_resolver` when `actual_key`
  already has a live connection.

  `connect_key` is `Map.get(clients, pid)` before the update—the provisional or
  prior registry key for this connection. Resolvers compare it to `actual_key`
  (`to_key(node_id)`) to decide whether to keep multiple simultaneous sessions.
  """
  def register_node_clients(clients, node_id, address, port, pid, conflict_resolver) do
    connect_key = Map.get(clients, pid)

    clients =
      clients
      |> Map.delete(pid)
      |> then(fn c -> if connect_key, do: Map.delete(c, connect_key), else: c end)

    actual_key = to_key(node_id)
    now = System.os_time(:millisecond)

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
            conflict_resolver.(
              clients,
              actual_key,
              pid,
              address,
              port,
              now,
              connect_key,
              entry
            )
        end
    end
  end

  def get_connections_from_state(clients) do
    clients
    |> Enum.filter(fn {_key, value} -> client_entry?(value) end)
    |> Enum.map(fn {key, value} -> {key, client_pid(value)} end)
    |> Map.new()
  end

  def get_ready_from_state(ready, clients) do
    ready
    |> Enum.filter(fn {address, pid} ->
      entry = Map.get(clients, address)
      client_entry?(entry) and client_pid(entry) == pid and Process.alive?(pid)
    end)
    |> Map.new()
  end

  def mark_ready(ready, clients, address, pid) do
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

  def handle_client_exit_noreply(state, pid, reason, label) do
    if reason not in [:normal, {:error, :closed}] do
      Logger.warning("#{label} Connection failed (#{inspect({pid, reason})})")
    end

    case Map.get(state.clients, pid) do
      nil ->
        {:noreply, state}

      key ->
        clients = Map.drop(state.clients, [pid, key])
        ready = Map.get(state, :ready, %{}) |> Map.delete(key)

        clients =
          Enum.find(clients, nil, fn {_entry, key0} -> key0 == key end)
          |> case do
            nil -> clients
            {pid0, key0} -> Map.put(clients, key0, client_entry(pid0))
          end

        {:noreply, %{state | clients: clients, ready: ready}}
    end
  end
end
