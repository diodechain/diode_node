defmodule Diode.Version do
  @patches elem(System.cmd("git", ["log", "-100", "--oneline"]), 0) |> String.split("\n")
  @description elem(System.cmd("git", ["describe", "--tags"]), 0)
  @version Regex.run(~r/v([0-9]+\.[0-9]+\.[0-9]+)/, @description) |> Enum.at(1)
  def patches() do
    @patches
  end

  def description() do
    String.trim(@description)
  end

  def version() do
    @version
  end
end
