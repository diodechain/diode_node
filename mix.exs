# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1

if String.to_integer(System.otp_release()) < 25 do
  IO.puts("this package requires OTP 25.")
  raise "incorrect OTP"
end

defmodule Diode.Mixfile do
  use Mix.Project

  @vsn "1.5.9"
  @url "https://github.com/diodechain/diode_node"

  def project do
    [
      aliases: aliases(),
      app: :diode,
      compilers: Mix.compilers(),
      deps: deps(),
      description: "Diode Network Relay Node",
      dialyzer: [plt_add_apps: [:mix]],
      docs: docs(),
      elixir: "~> 1.15",
      elixirc_options: [warnings_as_errors: Mix.target() == :host],
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      releases: [
        diode_node: [
          applications: [runtime_tools: :permanent, ssl: :permanent],
          steps: [:assemble, :tar],
          version: @vsn
        ]
      ],
      source_url: @url,
      start_permanent: Mix.env() == :prod,
      version: @vsn
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/helpers"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [mod: {Diode, []}, extra_applications: [:logger, :observer, :runtime_tools]]
  end

  defp aliases do
    [
      lint: [
        "compile",
        "format --check-formatted",
        "credo --only warning",
        "dialyzer"
      ]
    ]
  end

  defp docs do
    [
      source_ref: "v#{@vsn}",
      source_url: @url,
      formatters: ["html"],
      main: "readme",
      extras: [
        LICENSE: [title: "License"],
        "README.md": [title: "Readme"]
      ]
    ]
  end

  defp package do
    [
      maintainers: ["Dominic Letz"],
      licenses: ["DIODE"],
      links: %{github: @url},
      files: ~w(lib LICENSE mix.exs README.md)
    ]
  end

  defp deps do
    [
      {:certmagex, "~> 1.0"},
      {:debouncer, "~> 0.1"},
      {:dets_plus, "~> 2.0"},
      {:eblake2, "~> 1.0"},
      {:ex_doc, "~> 0.28", only: :dev, runtime: false},
      {:exqlite, "~> 0.17"},
      {:httpoison, "~> 2.0"},
      {:diode_client, github: "diodechain/diode_client_ex"},
      {:keccakf1600, github: "diodechain/erlang-keccakf1600"},
      {:libsecp256k1, "~> 0.1", hex: :libsecp256k1_diode_fork},
      {:oncrash, "~> 0.0"},
      {:plug_cowboy, "~> 2.5"},
      {:poison, "~> 6.0"},
      {:profiler, github: "dominicletz/profiler"},
      {:websockex, "~> 0.5", hex: :websockex_wt},

      # linting
      {:dialyxir, "~> 1.1", only: [:dev], runtime: false},
      {:credo, "~> 1.5", only: [:dev, :test], runtime: false},
      {:while, "~> 0.2", only: [:test], runtime: false}
    ]
  end
end
