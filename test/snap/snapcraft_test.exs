# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1

# Snap Store USN scans (e.g. USN-8737-2) are resolved by rebuilding when
# libc6 is staged from the Ubuntu archive without a version pin.
defmodule Snap.SnapcraftTest do
  use ExUnit.Case, async: true

  @snapcraft Path.expand("../../snap/snapcraft.yaml", __DIR__)

  setup_all do
    {:ok, yaml: File.read!(@snapcraft)}
  end

  test "uses core24 so staged debs come from Ubuntu 24.04 (noble)", %{yaml: yaml} do
    assert yaml =~ ~r/^base:\s*core24\s*$/m
  end

  test "does not pin apt sources that would freeze libc6 away from USNs", %{yaml: yaml} do
    refute yaml =~ ~r/^package-repositories:/m
  end

  test "libc6 is listed unpinned in build-packages and stage-packages", %{yaml: yaml} do
    for section <- ["build-packages", "stage-packages"] do
      packages = listed_packages(yaml, section)
      libc6 = Enum.filter(packages, &String.starts_with?(&1, "libc6"))

      assert libc6 == ["libc6"],
             "#{section} must list unpinned libc6 so a snap rebuild pulls archive security updates (USN-8737-2); got: #{inspect(libc6)}"
    end
  end

  defp listed_packages(yaml, section) do
    lines = String.split(yaml, "\n")

    start =
      Enum.find_index(lines, fn line ->
        String.match?(line, ~r/^\s{2,4}#{Regex.escape(section)}:\s*$/)
      end)

    assert is_integer(start), "missing #{section} in snap/snapcraft.yaml"

    lines
    |> Enum.drop(start + 1)
    |> Enum.take_while(&list_continuation?/1)
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\s+-\s+(\S+)\s*$/, line) do
        [_, pkg] -> [pkg]
        _ -> []
      end
    end)
  end

  defp list_continuation?(line) do
    String.match?(line, ~r/^\s*(?:#|$|- )/)
  end
end
