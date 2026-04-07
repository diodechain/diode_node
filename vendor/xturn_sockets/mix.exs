defmodule Xirsys.XTurn.Sockets.MixProject do
  use Mix.Project

  def project do
    [
      app: :xturn_sockets,
      version: "0.1.1",
      elixir: "~> 1.7",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Sockets library for the XTurn server.",
      source_url: "https://github.com/xirsys/xturn-sockets",
      homepage_url: "https://xturn.me",
      package: package(),
      docs: [
        extras: ["README.md", "LICENSE.md"],
        main: "readme"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssl]
    ]
  end

  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: :dev},
      {:xmedialib, "~> 0.1.1"}
    ]
  end

  defp package do
    %{
      files: ["lib", "mix.exs", "README.md", "LICENSE.md"],
      maintainers: ["Jahred Love"],
      licenses: ["Apache 2.0"],
      links: %{"Github" => "https://github.com/xirsys/xturn-sockets"}
    }
  end
end
