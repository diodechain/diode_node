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

    puts("====== ENV #{env()} ======")
    puts("Build       : #{version()}")
    puts("Edge2   Port: #{Enum.join(edge2_ports(), ",")}")
    puts("Peer2   Port: #{peer2_port()}")
    puts("RPC     Port: #{rpc_port()}")

    if ssl?() do
      puts("RPC SSL Port: #{rpcs_port()}")
    else
      puts("RPC SSL Port: DISABLED")
    end

    puts("Data Dir : #{data_dir()}")

    if System.get_env("COOKIE") do
      :erlang.set_cookie(String.to_atom(System.get_env("COOKIE")))
      puts("Cookie   : #{System.get_env("COOKIE")}")
    end

    puts("")

    {:ok, cache} = DetsPlus.open_file(:remoterpc_cache, file: data_dir("remoterpc.cache"))

    children =
      [
        worker(Stats, []),
        supervisor(Model.Sql),
        supervisor(Channels),
        worker(PubSub, [args]),
        worker(TicketStore, [])
        | Enum.map(RemoteChain.chains(), fn chain ->
            supervisor(RemoteChain.Sup, [chain, [cache: cache]], {RemoteChain.Sup, chain})
          end)
      ] ++
        [
          # External Interfaces
          Network.Server.child(peer2_port(), Network.PeerHandlerV2),
          worker(KademliaLight, [args])
        ]

    {:ok, pid} = Supervisor.start_link(children, strategy: :rest_for_one, name: Diode.Supervisor)
    start_client_network()
    {:ok, pid}
  end

  # To be started from the stage gen_server
  def start_client_network() do
    rpc_api(:http, port: rpc_port())

    if not dev_mode?() do
      ssl_rpc_api()
    end

    Supervisor.start_child(Diode.Supervisor, Network.Server.child(edge2_ports(), Network.EdgeV2))
    |> case do
      {:error, :already} -> Supervisor.restart_child(Diode.Supervisor, Network.EdgeV2)
      other -> other
    end
  end

  def stop_client_network() do
    Plug.Cowboy.shutdown(Network.RpcHttp.HTTP)
    Plug.Cowboy.shutdown(Network.RpcHttp.HTTPS)
    Supervisor.terminate_child(Diode.Supervisor, Network.EdgeV2)
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

  def puts(string, format \\ []) do
    if not test_mode?(), do: :io.format("#{string}~n", format)
  end

  defp rpc_api(scheme, opts) do
    puts("Starting rpc_#{scheme}...")

    apply(Plug.Cowboy, scheme, [
      Network.RpcHttp,
      [],
      [
        ip: {0, 0, 0, 0},
        compress: not Diode.dev_mode?(),
        dispatch: [
          {:_,
           [
             {"/ws", Network.RpcWs, []},
             {:_, Plug.Cowboy.Handler, {Network.RpcHttp, []}}
           ]}
        ]
      ] ++ opts
    ])
  end

  defp ssl?() do
    case File.read("priv/privkey.pem") do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp ssl_rpc_api() do
    if ssl?() do
      rpc_api(:https,
        keyfile: "priv/privkey.pem",
        certfile: "priv/cert.pem",
        cacertfile: "priv/fullchain.pem",
        port: rpcs_port(),
        otp_app: Diode
      )
    end
  end

  @version Mix.Project.config()[:full_version]
  def version() do
    "Diode Traffic Relay #{@version}"
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

  @spec data_dir(binary()) :: binary()
  def data_dir(file \\ "") do
    get_env("DATA_DIR", File.cwd!() <> "/data_" <> Atom.to_string(env()) <> "/") <> file
  end

  def host() do
    get_env("HOST", fn ->
      {:ok, interfaces} = :inet.getif()
      ips = Enum.map(interfaces, fn {ip, _b, _m} -> ip end)

      {a, b, c, d} =
        Enum.find(ips, hd(ips), fn ip ->
          case ip do
            {127, _, _, _} -> false
            {10, _, _, _} -> false
            {192, 168, _, _} -> false
            {172, b, _, _} when b >= 16 and b < 32 -> false
            _ -> true
          end
        end)

      "#{a}.#{b}.#{c}.#{d}"
    end)
  end

  @spec rpc_port() :: integer()
  def rpc_port() do
    get_env_int("RPC_PORT", 8545)
  end

  def rpcs_port() do
    get_env_int("RPCS_PORT", 8443)
  end

  @spec edge2_ports :: [integer()]
  def edge2_ports() do
    get_env("EDGE2_PORT", "41046,443,993,1723,10000")
    |> String.trim()
    |> String.split(",")
    |> Enum.map(fn port -> decode_int(String.trim(port)) end)
  end

  @spec peer2_port() :: integer()
  def peer2_port() do
    get_env_int("PEER2_PORT", default_peer2_port())
  end

  def default_peer2_port(), do: 51055

  def seeds() do
    case get_env("SEED2") do
      nil ->
        [
          # "diode://0xceca2f8cf1983b4cf0c1ba51fd382c2bc37aba58@us1.prenet.diode.io:51054",
          # "diode://0x7e4cd38d266902444dc9c8f7c0aa716a32497d0b@us2.prenet.diode.io:443",
          # "diode://0x68e0bafdda9ef323f692fc080d612718c941d120@as1.prenet.diode.io:51054",
          # "diode://0x1350d3b501d6842ed881b59de4b95b27372bfae8@as2.prenet.diode.io:443",
          # "diode://0x937c492a77ae90de971986d003ffbc5f8bb2232c@eu1.prenet.diode.io:51054",
          # "diode://0xae699211c62156b8f29ce17be47d2f069a27f2a6@eu2.prenet.diode.io:443"
        ]

      other ->
        other
        |> String.split(" ", trim: true)
        |> Enum.reject(fn item -> item == "none" end)
    end
  end

  @spec memory_mode() :: :normal | :minimal
  def memory_mode() do
    case get_env("MEMORY_MODE", "normal") do
      "normal" ->
        :normal

      "minimal" ->
        :minimal

      mode ->
        puts("Received unkown MEMORY_MODE #{mode}")
        :normal
    end
  end

  def self(), do: self(host())

  def self(hostname) do
    Object.Server.new(hostname, hd(edge2_ports()), peer2_port(), version(), [
      ["tickets", TicketStore.value(TicketStore.epoch())],
      ["uptime", Diode.uptime()],
      ["time", System.os_time()]
    ])
    |> Object.Server.sign(Wallet.privkey!(Diode.wallet()))
  end

  def get_env(name, default \\ nil) do
    case System.get_env(name) do
      nil when is_function(default) -> default.()
      nil -> default
      other -> other
    end
  end

  def get_env_int(name, default) do
    decode_int(get_env(name, default))
  end

  defp decode_int(int) do
    case int do
      "" ->
        0

      <<"0x", _::binary>> = bin ->
        Base16.decode_int(bin)

      bin when is_binary(bin) ->
        {num, _} = Integer.parse(bin)
        num

      int when is_integer(int) ->
        int
    end
  end

  def uptime() do
    {uptime, _} = :erlang.statistics(:wall_clock)
    uptime
  end
end
