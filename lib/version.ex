defmodule Diode.Version do
  @patches elem(System.cmd("git", ["log", "-100", "--oneline"]), 0) |> String.split("\n")
  @description elem(System.cmd("git", ["describe", "--tags"]), 0)
  def patches() do
    @patches
  end

  def description() do
    @description
  end
end
