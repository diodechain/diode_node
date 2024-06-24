#!/usr/bin/env elixir

Mix.install(decorator: "~> 1.4")

defmodule Fabric do
  defmacro __using__(_) do
    quote do
      import Fabric.API
      use Fabric.Decorator
    end
  end

  alias Fabric.API

  def run(fabfile) do
    fabfile.init()
    command = parse(System.argv()) |> String.to_atom()
    commands = for {name, 0} <- fabfile.__info__(:functions), do: name

    if command not in commands do
      IO.puts("Usage: ./fabfile.exs <command>")
      IO.puts("Available commands:")

      for {name, 0} <- fabfile.__info__(:functions) do
        IO.puts("  #{name}")
      end

      System.halt(1)
    else
      for host <- API.env().hosts do
        {user, host} = case String.split(host, "@") do
          [user, host] -> {user, host}
        end

        API.put_env(:host, host)
        API.put_env(:user, user)
        apply(fabfile, command, [])
      end
    end
  end

  defp parse([command]) do
    command
  end

  defp parse([]) do
    nil
  end
end

defmodule Fabric.API do
  def env() do
    Process.get({__MODULE__, :env}) || %{hosts: []}
  end

  def put_env(key, value) do
    Process.put({__MODULE__, :env}, Map.put(env(), key, value))
  end

  def exists(path) do
    IO.puts("exists?: #{path}")
    false
  end

  def run(cmd) do
    IO.puts("run: #{cmd}")
  end

  def put(local, remote) do
    IO.puts("put: #{local} -> #{remote}")
  end

  def cd(dir) do
    IO.puts("cd: #{dir}")
  end

  @doc """
  Run a command locally

  ## Examples

      local("ls -la")

  ## Options

  * `:capture` - capture the output of the command
  """
  def local(cmd, opts \\ []) do
    {output, ret} = System.cmd("bash", ["-c", cmd])

    if ret != 0 do
      raise "local: #{cmd} failed with exit code #{ret} and output:\n#{output}"
    end

    case Keyword.get(opts, :capture) do
      true -> output
      _ -> IO.puts(output)
    end
  end

  def hide(type1, type2 \\ nil, type3 \\ nil, type4 \\ nil, type5 \\ nil) do
    args = [type1, type2, type3, type4, type5] |> Enum.filter(&(&1 != nil))
    IO.puts("hide: #{inspect(args)}")
  end

  defmacro with_do(do: block) do
    quote do
      unquote(block)
    end
  end
end

defmodule Fabric.Decorator do
  use Decorator.Define, parallel: 0

  def parallel(body, context) do
    quote do
      IO.puts("Function parallel: " <> Atom.to_string(unquote(context.name)))
      unquote(body)
    end
  end
end

defmodule MyFabfile do
  use Fabric

  def init() do
    put_env(:gateway, "root@eu1.prenet.diode.io")
    put_env(:diode, "/opt/diode_node")

    if length(env().hosts) == 0 do
      put_env(:hosts, [
        "root@eu1.prenet.diode.io",
        "root@eu2.prenet.diode.io",
        "root@us1.prenet.diode.io",
        "root@us2.prenet.diode.io",
        "root@as1.prenet.diode.io",
        "root@as2.prenet.diode.io",
        "root@as3.prenet.diode.io"
      ])
    end
  end

  def install() do
    run("mkdir -p #{env().diode}")
    cd(env().diode)
    h = local("sha1sum ../_build/prod/diode_node.tar.gz", capture: true).split()[0]

    if not exists("diode_node.tar.gz") or h != run("sha1sum diode_node.tar.gz").split()[0] do
      put("../_build/prod/diode_node.tar.gz", env().diode)

      if exists("releases/COOKIE") do
        run("tar xzf diode_node.tar.gz --exclude=releases/COOKIE")
      else
        run("tar xzf diode_node.tar.gz")
      end
    end
  end

  @decorate parallel()
  def check() do
    with_do do
      hide(~c"status", ~c"running")
      local("echo | nc -q0  #{env().host} 41046 && echo #{env().host}=ok")
    end

    run("/opt/diode_node/bin/diode_node pid")
  end

  @decorate parallel()
  def version() do
    run(
      "/opt/diode_node/bin/diode_node rpc 'IO.inspect(String.trim(Diode.Version.description()))'"
    )
  end

  def stop() do
    cd(env().diode)
    run("bin/diode_node stop")
  end

  def uninstall() do
    cd(env().diode)

    if exists("bin/diode_node") do
      run("rm bin/diode_node")
      # run("killall beam.smp")
    end

    run("epmd -names")
  end

  def epmd() do
    run("epmd -names")
    run("ps waux | grep diode_node")
  end
end

Fabric.run(MyFabfile)
