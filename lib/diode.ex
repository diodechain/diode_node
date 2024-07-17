# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
require Logger

defmodule Diode do
  use Application

  def start(type, args) do
    if Application.get_env(:diode, :no_start) do
      Supervisor.start_link([], strategy: :rest_for_one, name: Diode.Supervisor)
    else
      do_start(type, args)
    end
  end

  @env Mix.env()
  @spec env :: :prod | :test | :dev
  def env() do
    :persistent_term.get(:env, @env)
  end

  defp do_start(_type, args) do
    :erlang.system_flag(:backtrace_depth, 30)
    Diode.Config.configure()

    puts("====== ENV #{env()} ======")
    puts("Build       : #{Diode.Version.description()}")
    puts("Edge2   Port: #{Enum.join(edge2_ports(), ",")}")
    puts("Peer2   Port: #{peer2_port()}")
    puts("RPC     Port: #{rpc_port()}")
    puts("RPC SSL Port: #{rpcs_port()}")

    puts("Data Dir : #{data_dir()}")

    if System.get_env("COOKIE") do
      :erlang.set_cookie(String.to_atom(System.get_env("COOKIE")))
      puts("Cookie   : #{System.get_env("COOKIE")}")
    end

    puts("")

    children =
      [
        Stats,
        Network.Stats,
        supervisor(Model.Sql),
        TicketStore,
        Cron,
        supervisor(Channels),
        {PubSub, args},
        {DetsPlus, name: :remoterpc_cache}
      ]

    with {:ok, pid} <-
           Supervisor.start_link(children, strategy: :rest_for_one, name: Diode.Supervisor) do
      cache = DetsPlus.LRU.new(:remoterpc_cache, 1_000_000, fn obj -> obj != nil end)

      [
        Enum.map(RemoteChain.chains(), fn chain ->
          supervisor(RemoteChain.Sup, [chain, [cache: cache]], {RemoteChain.Sup, chain})
        end),
        Network.Server.child(peer2_port(), Network.PeerHandlerV2),
        supervisor(
          Supervisor,
          [network_children(), [strategy: :one_for_one, name: Network]],
          Network
        ),
        worker(KademliaLight, [args])
      ]
      |> List.flatten()
      |> Enum.each(fn child ->
        {:ok, _} = Supervisor.start_child(pid, child)
      end)

      {:ok, pid}
    end
  end

  def network_children() do
    [
      Network.Server.child(edge2_ports(), Network.EdgeV2),
      rpc_api(:http, port: rpc_port()),
      rpc_api(:https, port: rpcs_port(), sni_fun: &CertMagex.sni_fun/1)
    ]
  end

  def start_client_network() do
    for child <- network_children() do
      Supervisor.start_child(Network, child)
    end
  end

  def stop_client_network() do
    for child <- Supervisor.which_children(Network) do
      Supervisor.terminate_child(Network, elem(child, 0))
    end
  end

  defp worker(module, args) do
    %{id: module, start: {Diode, :start_worker, [module, args]}}
  end

  defp supervisor(module, args \\ [], id \\ nil) do
    %{
      id: id || module,
      start: {Diode, :start_worker, [module, args]},
      shutdown: :infinity,
      type: :supervisor
    }
  end

  def start_worker(module, args) do
    # puts("Starting #{module}...")

    case :timer.tc(module, :start_link, args) do
      {_t, {:ok, pid}} ->
        # puts("=======> #{module} loaded after #{Float.round(t / 1_000_000, 3)}s")
        {:ok, pid}

      {_t, other} ->
        puts("=======> #{module} failed with: #{inspect(other)}")
        other
    end
  end

  def puts(string) do
    if not test_mode?(), do: IO.puts(string)
  end

  defp rpc_api(scheme, opts) do
    dispatch =
      {:_, [{"/ws", Network.RpcWs, []}, {:_, Plug.Cowboy.Handler, {Network.RpcHttp, []}}]}

    opts =
      [ip: {0, 0, 0, 0}, compress: not Diode.dev_mode?(), dispatch: [dispatch]]
      |> Keyword.merge(opts)

    {Plug.Cowboy, scheme: scheme, plug: Network.RpcHttp, options: opts}
  end

  @spec dev_mode? :: boolean
  def dev_mode?() do
    env() == :dev or env() == :test
  end

  @spec test_mode? :: boolean
  def test_mode?() do
    env() == :test
  end

  @spec trace? :: boolean
  def trace?() do
    true == :persistent_term.get(:trace, false)
  end

  @spec trace(boolean) :: any
  def trace(enabled) when is_boolean(enabled) do
    :persistent_term.put(:trace, enabled)
  end

  @doc "Number of bytes the server is willing to send without payment yet."
  def ticket_grace() do
    :persistent_term.get(:ticket_grace, 1024 * 40_960)
  end

  def ticket_grace(bytes) when is_integer(bytes) do
    :persistent_term.put(:ticket_grace, bytes)
  end

  @spec hash(binary()) :: binary()
  def hash(bin) do
    # Ethereum is using KEC instead ...
    Hash.sha3_256(bin)
  end

  @spec wallet() :: Wallet.t()
  def wallet() do
    Model.CredSql.wallet()
  end

  def address() do
    Wallet.address!(wallet())
  end

  def data_dir(file \\ "") do
    Path.join(Diode.Config.get("DATA_DIR"), file)
  end

  def host() do
    Diode.Config.get("HOST")
  end

  @spec rpc_port() :: integer()
  def rpc_port() do
    Diode.Config.get_int("RPC_PORT")
  end

  def rpcs_port() do
    Diode.Config.get_int("RPCS_PORT")
  end

  @spec edge2_ports :: [integer()]
  def edge2_ports() do
    Diode.Config.get("EDGE2_PORT")
    |> String.trim()
    |> String.split(",", trim: true)
    |> Enum.map(fn port -> String.to_integer(String.trim(port)) end)
  end

  @spec peer2_port() :: integer()
  def peer2_port() do
    Diode.Config.get_int("PEER2_PORT")
  end

  def default_peer2_port(), do: 51055

  def seeds() do
    Diode.Config.get("SEED_LIST")
    |> String.split(" ", trim: true)
    |> Enum.reject(fn item -> item == "none" end)
  end

  def self(), do: self(host())

  def self(hostname) do
    Object.Server.new(hostname, hd(edge2_ports()), peer2_port(), Diode.Version.version(), [
      ["tickets", TicketStore.epoch_score()],
      ["uptime", Diode.uptime()],
      ["time", System.os_time()],
      ["block", RemoteChain.peaknumber(Chains.Moonbeam)]
    ])
    |> Object.Server.sign(Wallet.privkey!(Diode.wallet()))
  end

  def broadcast_self() do
    Debouncer.immediate(
      :broadcast_self,
      fn -> KademliaLight.store(Diode.self()) end,
      10_000
    )
  end

  def maybe_import_key() do
    paths =
      ["priv", System.get_env("CERT_PATH", ""), System.get_env("PARENT_CWD", "")]
      |> Enum.uniq()
      |> Enum.map(&Path.absname/1)

    Logger.info("maybe_import_key: Checking #{inspect(paths)}'")

    for path <- paths do
      with {:ok, privkey} <- File.read(Path.join(path, "privkey.pem")),
           {:ok, pubcert} <- File.read(Path.join(path, "fullchain.pem")) do
        Logger.info("maybe_import_key: Importing cert from '#{path}'")
        CertMagex.insert(privkey, pubcert)
      end
    end
  end

  def uptime() do
    {uptime, _} = :erlang.statistics(:wall_clock)
    uptime
  end
end
