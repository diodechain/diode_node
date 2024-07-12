defmodule Diode.Cmd do
  @moduledoc """
  Diode Snap command line interface functions
  """

  def configure() do
    Diode.Config.configure()
  end

  def status() do
    IO.puts("== Diode Node #{Wallet.base16(Diode.wallet())} ==")
    IO.puts("Version          : #{Diode.Version.version()}")

    if "v" <> Diode.Version.version() != Diode.Version.description() do
      IO.puts("Description      : #{Diode.Version.description()}")
    end

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
  end
end
