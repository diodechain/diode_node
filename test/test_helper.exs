# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
ExUnit.start(seed: 0)

defmodule ChainAgent do
  use GenServer
  defstruct port: nil, out: ""

  def init(_args) do
    {:ok, %ChainAgent{}}
  end

  def handle_call(:restart, _from, state = %{port: port}) do
    System.cmd("killall", ["anvil"])

    if port != nil do
      Port.close(port)
      Process.sleep(500)
    end

    port =
      Port.open({:spawn_executable, System.find_executable("anvil")}, [
        :stream,
        :exit_status,
        :hide,
        :use_stdio,
        :binary,
        :stderr_to_stdout
      ])

    state = await(%{state | port: port, out: ""})
    {:reply, :ok, state}
  end

  defp await(state = %{port: port, out: out}) do
    if String.contains?(out, "Listening on") do
      wallets =
        for n <- 0..9 do
          [_, privkey] = Regex.run(~r/\(#{n}\) (0x[a-f0-9]{64})/, out)

          Base16.decode(privkey)
          |> Wallet.from_privkey()
        end

      # SSL Servers already started here
      Model.CredSql.set_wallet(hd(wallets))
      Supervisor.terminate_child(Diode.Supervisor, Network.EdgeV2)
      Supervisor.terminate_child(Diode.Supervisor, Network.PeerHandler)
      Supervisor.restart_child(Diode.Supervisor, Network.EdgeV2)
      Supervisor.restart_child(Diode.Supervisor, Network.PeerHandler)

      wallets = Enum.map(wallets, fn w -> Base16.encode(Wallet.privkey!(w)) end) |> Enum.join(" ")
      System.put_env("WALLETS", wallets)

      # IO.puts(out)
      # RemoteChain.RPC.rpc!(Chains.Anvil, "evm_setAutomine", [true])
      IO.puts("Anvil started")
      state
    else
      receive do
        {^port, {:data, data}} ->
          state = %{state | out: out <> data}
          await(state)

        other ->
          raise "Unexpected message: #{inspect(other)}"
      end
    end
  end

  def handle_info({port0, {:data, msg}}, state = %{out: out, port: port}) do
    if port0 == port do
      IO.puts(msg)
      {:noreply, %{state | out: out <> msg}}
    else
      {:noreply, %{state | out: out}}
    end
  end
end

defmodule TestHelper do
  @delay_clone 10_000
  @cookie "EXTMP_K66"
  @max_ports 10
  @chain Chains.Anvil

  def chain(), do: @chain
  def peaknumber(), do: RemoteChain.peaknumber(@chain)
  def developer_fleet_address(), do: RemoteChain.developer_fleet_address(@chain)
  def epoch(), do: RemoteChain.epoch(@chain)

  def reset() do
    kill_clones()
    TicketStore.clear()
    Kademlia.reset()
    restart_chain()
  end

  def restart_chain() do
    chaintask =
      Process.whereis(RemoteChain.Anvil) ||
        elem(GenServer.start(ChainAgent, [], name: RemoteChain.Anvil), 1)

    GenServer.call(chaintask, :restart)
  end

  def wait(n) do
    case peaknumber() >= n do
      true ->
        :ok

      false ->
        :io.format("Waiting for block ~p/~p~n", [n, peaknumber()])
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
    kill_clones()
    basedir = File.cwd!() <> "/clones"
    File.rm_rf!(basedir)
    File.mkdir!(basedir)

    for num <- 1..number do
      add_clone(num)
    end

    :ok = wait_clones(number, 60)
    Process.sleep(@delay_clone)
  end

  def add_clone(num) do
    basedir = File.cwd!() <> "/clones"
    clonedir = "#{basedir}/#{num}/"
    file = File.open!("#{basedir}/#{num}.log", [:write, :binary])

    spawn_link(fn ->
      iex = System.find_executable("iex")
      args = ["--cookie", @cookie, "-S", "mix", "run"]

      env =
        [
          {"MIX_ENV", "test"},
          {"DATA_DIR", clonedir},
          {"RPC_PORT", "#{rpc_port(num)}"},
          {"RPCS_PORT", "#{rpcs_port(num)}"},
          {"EDGE2_PORT", "#{edge2_port(num)}"},
          {"PEER2_PORT", "#{peer_port(num)}"},
          {"SEED", "none"}
        ]
        |> Enum.map(fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)

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

      # :io.format("port clone_#{num}: ~p~n", [port])
      true = Process.register(port, String.to_atom("clone_#{num}"))

      clone_loop(port, file)
    end)
  end

  defp clone_loop(port, file) do
    receive do
      {^port, {:data, msg}} ->
        IO.write(file, msg)

      msg ->
        :io.format("RECEIVED: ~p~n", [msg])
    end

    clone_loop(port, file)
  end

  def freeze_clone(num) do
    port = Process.whereis(String.to_atom("clone_#{num}"))
    # :io.format("port info: ~p ~p~n", [port, Port.info(port)])
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
