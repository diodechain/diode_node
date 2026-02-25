# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
ExUnit.start(seed: 0)

defmodule ChainAgent do
  alias DiodeClient.{Base16, Wallet}

  use GenServer
  defstruct port: nil, out: "", log: nil

  def init(_args) do
    log = File.open!("anvil.log", [:write, :binary])
    {:ok, %ChainAgent{log: log}}
  end

  def handle_call(:restart, _from, state) do
    {:reply, :ok, do_restart(state)}
  end

  defp do_restart(state = %{port: port}) do
    System.cmd("killall", ["-w", "anvil"])

    if port != nil do
      try do
        Port.close(port)
      rescue
        _ -> :ok
      end

      Process.sleep(500)
    end

    port =
      Port.open({:spawn_executable, System.find_executable("anvil")}, [
        :stream,
        :exit_status,
        :hide,
        :use_stdio,
        :binary,
        :stderr_to_stdout,
        {:args, ["--port", "#{Chains.Anvil.port()}"]}
      ])

    await(%{state | port: port, out: ""})
  end

  defp await(state = %{port: port, out: out, log: log}) do
    if String.contains?(out, "Listening on") do
      hostport =
        Regex.run(~r/Listening on (.*)/, out)
        |> hd()
        |> String.split(":")
        |> tl()
        |> Enum.join(":")

      IO.puts(log, "Anvil started on #{hostport}")

      wallets =
        for n <- 0..9 do
          [_, privkey] = Regex.run(~r/\(#{n}\) (0x[a-f0-9]{64})/, out)

          Base16.decode(privkey)
          |> Wallet.from_privkey()
        end

      # SSL Servers already started here
      TestHelper.set_wallets(wallets)
      Model.CredSql.set_wallet(hd(wallets))
      restart_service(Network.EdgeV2)
      restart_service(Network.PeerHandlerV2)
      restart_service(KademliaLight)
      RemoteChain.NodeProxy.reset_lastblock(Chains.Anvil)
      RemoteChain.RPCCache.reset_block_number(Chains.Anvil)
      Process.sleep(1000)
      # Allow WS to send first block after reset so RPCCache gets fresh block_number

      wallets = Enum.map(wallets, fn w -> Base16.encode(Wallet.privkey!(w)) end) |> Enum.join(" ")
      System.put_env("WALLETS", wallets)

      # Need to mine one block to ensure the chain is ready (NodeProxy checks block == 0)
      RemoteChain.RPC.rpc!(Chains.Anvil, "anvil_mine", [1])
      IO.puts(log, "Anvil started")
      state
    else
      receive do
        {^port, {:data, data}} ->
          state = %{state | out: out <> data}
          await(state)

        {^port, {:exit_status, status}} ->
          IO.puts(log, "Anvil exited with status #{status}")
          do_restart(%{state | port: nil})

        {_other_port, {:data, _}} ->
          # Ignore data from old/different port (e.g. messages in mailbox from before restart)
          await(state)

        {_other_port, {:exit_status, _status}} ->
          # this is another previously closed port
          await(state)

        other ->
          raise "Unexpected message: #{inspect(other)}"
      end
    end
  end

  defp restart_service(what) do
    Supervisor.terminate_child(Diode.Supervisor, what)
    Supervisor.restart_child(Diode.Supervisor, what)
  end

  def handle_info({port0, {:exit_status, status}}, state = %{log: log, port: port}) do
    if port0 == port do
      IO.puts(log, "Anvil exited with status #{status}")
      {:noreply, do_restart(%{state | port: nil})}
    else
      {:noreply, state}
    end
  end

  def handle_info({port0, {:data, msg}}, state = %{log: log, out: out, port: port}) do
    if port0 == port do
      IO.puts(log, msg)
      {:noreply, %{state | out: out <> msg}}
    else
      {:noreply, state}
    end
  end
end

defmodule TestHelper do
  alias DiodeClient.{Base16, Wallet}

  @delay_clone 10_000
  @cookie "EXTMP_K66"
  @max_ports 10
  @chain Chains.Anvil
  require Logger

  def chain(), do: @chain
  def peaknumber(), do: RemoteChain.peaknumber(@chain)
  def developer_fleet_address(), do: RemoteChain.developer_fleet_address(@chain)
  def epoch(), do: RemoteChain.epoch(@chain)

  def reset() do
    kill_clones()
    TicketStore.clear()
    KademliaLight.reset()
    restart_chain()
  end

  def set_wallets(wallets) do
    :persistent_term.put(:wallets, wallets)
    wallets
  end

  def wallets() do
    case :persistent_term.get(:wallets, nil) do
      nil ->
        set_wallets(
          for _ <- 0..9 do
            Wallet.new()
          end
        )

      wallets ->
        wallets
    end
  end

  def restart_chain() do
    chaintask =
      Process.whereis(RemoteChain.Anvil) ||
        elem(GenServer.start(ChainAgent, [], name: RemoteChain.Anvil), 1)

    GenServerDbg.call(chaintask, :restart, 15_000)
  end

  def wait(n) do
    case peaknumber() >= n do
      true ->
        :ok

      false ->
        Logger.info("Waiting for block #{n}/#{peaknumber()}")
        Process.sleep(1000)
        wait(n)
    end
  end

  def edge2_port(num) do
    20004 + num * @max_ports
  end

  def peer_port(num) do
    20001 + num * @max_ports
  end

  def rpc_port(num) do
    20002 + num * @max_ports
  end

  def rpcs_port(num) do
    20003 + num * @max_ports
  end

  def name_clone(n) do
    {:ok, name} = :inet.gethostname()
    String.to_atom("clone_#{n}@#{name}")
  end

  def start_clones(number) do
    start_clones(number, [])
  end

  @doc """
  Start clone nodes for multi-node tests. Options:
  - :peer_wiring - when true, configures clones to connect to main (SEED) and
    main to know clones (DEFAULT_PEER_LIST). Requires wallets to be set.
    Uses wallet[num] for clone num to get deterministic node_ids.
  """
  def start_clones(number, opts) do
    kill_clones()
    basedir = File.cwd!() <> "/clones"
    File.rm_rf!(basedir)
    File.mkdir!(basedir)

    peer_wiring = Keyword.get(opts, :peer_wiring, false)
    main_peer_uri = peer_wiring && main_peer_uri()
    wallets = peer_wiring && wallets()

    for num <- 1..number do
      clone_opts =
        if peer_wiring do
          [
            seed: main_peer_uri,
            private_key:
              Wallet.privkey!(Enum.at(wallets, num)) |> Base16.encode() |> then(&"0x#{&1}")
          ]
        else
          []
        end

      add_clone(num, clone_opts)
    end

    :ok = wait_clones(number, 60)
    Process.sleep(@delay_clone)
  end

  defp main_peer_uri() do
    "diode://#{Base16.encode(Diode.address())}@localhost:#{Diode.peer2_port()}"
  end

  @doc """
  Configure main node's DEFAULT_PEER_LIST to include clones for cross-node message forwarding.
  Call before running cross-node tests. Clones must be started with :peer_wiring.
  """
  def configure_main_peer_list_for_clones(number) do
    wallets = wallets()
    peer_uris = for num <- 1..number, do: clone_peer_uri(num, Enum.at(wallets, num))
    Diode.Config.set("DEFAULT_PEER_LIST", Enum.join(peer_uris, " "))
    # Trigger KademliaLight to contact seeds immediately
    send(KademliaLight, :contact_seeds)
    Process.sleep(2000)
    :ok
  end

  defp clone_peer_uri(num, wallet) do
    "diode://#{Base16.encode(Wallet.address!(wallet))}@localhost:#{peer_port(num)}"
  end

  def add_clone(num, opts \\ []) do
    basedir = File.cwd!() <> "/clones"
    clonedir = "#{basedir}/#{num}/"
    file = File.open!("#{basedir}/#{num}.log", [:write, :binary])

    seed = Keyword.get(opts, :seed, "none")
    private_key = Keyword.get(opts, :private_key)

    env =
      [
        {"MIX_ENV", "test"},
        {"DATA_DIR", clonedir},
        {"RPC_PORT", "#{rpc_port(num)}"},
        {"RPCS_PORT", "#{rpcs_port(num)}"},
        {"EDGE2_PORT", "#{edge2_port(num)}"},
        {"PEER2_PORT", "#{peer_port(num)}"},
        {"SEED", seed}
      ]
      |> (fn list ->
            if private_key, do: [{"PRIVATE", private_key} | list], else: list
          end).()
      |> Enum.map(fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)

    spawn_link(fn ->
      iex = System.find_executable("iex")
      args = ["--cookie", @cookie, "-S", "mix", "run"]

      port =
        Port.open({:spawn_executable, iex}, [
          {:args, args},
          {:env, env},
          :stream,
          :exit_status,
          :hide,
          :use_stdio,
          :stderr_to_stdout
        ])

      true = Process.register(port, String.to_atom("clone_#{num}"))
      clone_loop(port, file)
    end)
  end

  defp clone_loop(port, file) do
    receive do
      {^port, {:data, msg}} ->
        IO.write(file, msg)
        clone_loop(port, file)

      {^port, {:exit_status, status}} ->
        {:exit_status, status}

      msg ->
        IO.puts("RECEIVED: #{inspect(msg)}")
    end

    clone_loop(port, file)
  end

  def freeze_clone(num) do
    port = Process.whereis(String.to_atom("clone_#{num}"))
    {:os_pid, pid} = Port.info(port, :os_pid)
    System.cmd("kill", ["-SIGSTOP", "#{pid}"])
  end

  def unfreeze_clone(num) do
    port = Process.whereis(String.to_atom("clone_#{num}"))
    {:os_pid, pid} = Port.info(port, :os_pid)
    System.cmd("kill", ["-SIGCONT", "#{pid}"])
  end

  def wait_clones(_target_count, 0) do
    :error
  end

  def wait_clones(target_count, seconds) do
    timeout = System.os_time(:second) + seconds

    Enum.map(1..target_count, &peer_port/1)
    |> wait_tcp(timeout)
  end

  def wait_tcp([], _timeout), do: :ok

  def wait_tcp([port | rest] = ports, timeout) do
    if System.os_time(:second) > timeout do
      :error
    else
      case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :line, active: false], 1000) do
        {:ok, port} ->
          :gen_tcp.close(port)
          wait_tcp(rest, timeout)

        {:error, _} ->
          Process.sleep(100)
          wait_tcp(ports, timeout)
      end
    end
  end

  def is_macos() do
    :os.type() == {:unix, :darwin}
  end

  def count_clones() do
    if is_macos() do
      {ret, _} = System.cmd("pgrep", ["-f", @cookie])
      String.split(ret, "\n", trim: true) |> Enum.count()
    else
      {ret, _} = System.cmd("pgrep", ["-fc", @cookie])
      {count, _} = Integer.parse(ret)
      count
    end
  end

  def kill_clones() do
    System.cmd("pkill", ["-9", "-f", @cookie])
    wait_for(fn -> count_clones() == 0 end, "kill clones", 60)
  end

  def wait_for(fun, comment, timeout \\ 10)

  def wait_for(_fun, comment, 0) do
    msg = "Failed to wait for #{comment}"
    IO.puts(msg)
    throw(msg)
  end

  def wait_for(fun, comment, timeout) do
    case fun.() do
      true ->
        :ok

      false ->
        IO.puts("Waiting for #{comment} t-#{timeout}")
        Process.sleep(1000)
        wait_for(fun, comment, timeout - 1)
    end
  end

  def deploy_contract(name) do
    key = System.get_env("WALLETS") |> Enum.split(" ") |> hd()

    {text, 0} =
      System.cmd("forge", [
        "create",
        "--rpc-url",
        "http://localhost:8545",
        "--private-key",
        key,
        "contract_src/#{name}.sol:#{name}"
      ])

    IO.puts(text)
  end
end

TestHelper.restart_chain()
