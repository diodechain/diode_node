defmodule Diode.Cmd do
  @moduledoc """
  Diode Snap command line interface functions
  """

  alias DiodeClient.{Wallet, Base16}

  def configure() do
    Diode.Config.configure()
  end

  def flush_cache() do
    Exqlite.LRU.flush()
    Exqlite.LRU.flush(Network.Stats.LRU)
    BinaryLRU.flush(:memory_cache)
  end

  def status() do
    IO.puts("== Diode Node #{Wallet.base16(Diode.wallet())} ==")
    IO.puts("Name             : #{Diode.Config.get("NAME")}")
    IO.puts("Version          : #{Diode.Version.version()}")

    if "v" <> Diode.Version.version() != Diode.Version.description() do
      IO.puts("Description      : #{Diode.Version.description()}")
    end

    IO.puts("Accountant       : #{Base16.encode(Diode.Accountant.address())}")
    IO.puts("Uptime           : #{div(Diode.uptime(), 1000)}")

    devcount = Network.Server.get_connections(Network.EdgeV2) |> Enum.count()
    IO.puts("Connected Devices: #{devcount}")
    peercount = Network.Server.get_connections(Network.PeerHandlerV2) |> Enum.count()
    IO.puts("Connected Peers  : #{peercount}")
    IO.puts("")

    chain = Chains.Moonbeam
    epoch = RemoteChain.epoch(chain)
    IO.puts("Current Epoch    : #{epoch}")
    IO.puts("Ticket Score     : #{TicketStore.epoch_score(epoch)}")
    IO.puts("")

    IO.puts("Previous Epoch   : #{epoch - 1}")
    IO.puts("Ticket Score     : #{TicketStore.epoch_score(epoch - 1)}")
    IO.puts("")
    IO.puts("Dashboard        : https://diode.io/network/#/node/#{Wallet.base16(Diode.wallet())}")
  end

  def env() do
    for {var, value} <- Enum.sort(System.get_env()) do
      IO.puts("#{String.pad_trailing(var, 20)} = #{value}")
    end
  end
end
