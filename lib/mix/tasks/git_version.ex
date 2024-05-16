defmodule Mix.Tasks.GitVersion do
  use Mix.Task
  require Logger

  @impl Mix.Task
  def run(args) do
    case System.cmd("git", ["describe", "--tags", "--dirty"]) do
      {version, 0} ->
        Regex.run(~r/v([0-9]+\.[0-9]+\.[0-9]+)(-.*)?/, version)
        |> case do
          [full_vsn, vsn | _rest] ->
            :persistent_term.put(:vsn, vsn)

            bin = original = File.read!("mix.exs")
            bin = Regex.replace(~r/\@vsn .*/, bin, "@vsn \"#{vsn}\"", global: false)

            bin =
              Regex.replace(~r/\@full_vsn .*/, bin, "@full_vsn \"#{full_vsn}\"", global: false)

            if bin != original, do: File.write!("mix.exs", bin)

          other ->
            Logger.error("Couldn't parse version #{inspect(other)}")
        end

      other ->
        Logger.error("Couldn't check git version #{inspect(other)}")
    end

    IO.puts(Enum.join(args, " "))
  end
end
