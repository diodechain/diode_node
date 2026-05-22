# Diode Server
# Copyright 2021-2025 Diode
# Licensed under the Diode License, Version 1.1
defmodule KademliaLightRpcTest do
  use ExUnit.Case, async: true

  alias DiodeClient.Wallet

  defmodule SlowPeer do
    use GenServer

    def start_link(delay_ms), do: GenServer.start_link(__MODULE__, delay_ms)

    @impl true
    def init(delay_ms), do: {:ok, delay_ms}

    @impl true
    def handle_call({:rpc, _call}, from, delay_ms) do
      Process.send_after(self(), {:reply, from}, delay_ms)
      {:noreply, delay_ms}
    end

    @impl true
    def handle_info({:reply, from}, delay_ms) do
      GenServer.reply(from, ["ok"])
      {:noreply, delay_ms}
    end
  end

  test "rpc_with_cutoff returns empty before slow peer responds" do
    {:ok, pid} = SlowPeer.start_link(3000)
    wallet = Wallet.new()

    assert [] == KademliaLight.rpc_with_cutoff_test(wallet, pid, [:ping])
  end

  test "rpc_with_cutoff logs when peer responds after lookup cutoff" do
    {:ok, pid} = SlowPeer.start_link(3000)
    wallet = Wallet.new()
    printable = Wallet.printable(wallet)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert [] == KademliaLight.rpc_with_cutoff_test(wallet, pid, [:ping])
        Process.sleep(3500)
      end)

    assert log =~ "Slow RPC from #{printable}"
    assert log =~ "completed in 3"
    assert log =~ "lookup cutoff 2000ms"
  end

  test "rpc_with_cutoff returns result within cutoff" do
    {:ok, pid} = SlowPeer.start_link(10)
    wallet = Wallet.new()

    assert ["ok"] == KademliaLight.rpc_with_cutoff_test(wallet, pid, [:ping])
  end
end
