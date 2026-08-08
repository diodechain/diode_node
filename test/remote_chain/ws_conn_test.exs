defmodule RemoteChain.WSConnTest do
  use ExUnit.Case, async: true

  alias RemoteChain.WSConn

  defmodule WSConnStateStub do
    @moduledoc """
    In-process stand-in for a WSConn so the staleness predicate can be
    tested without opening a real socket. `:sys.get_state/2` returns the
    `WSConn` struct we configure here.
    """
    use GenServer

    def start(state) do
      GenServer.start(__MODULE__, state)
    end

    @impl true
    def init(state), do: {:ok, state}
  end

  describe "stale?/2" do
    test "is false for a connection whose last block is fresh" do
      {:ok, pid} = WSConnStateStub.start(%WSConn{lastblock_at: DateTime.utc_now()})
      refute WSConn.stale?(pid, Chains.Anvil)
    end

    test "is true once the last block is older than expected_block_intervall * 10" do
      # Anvil uses 15s intervals; 11 intervals = 165s puts us clearly past the
      # 10-interval cutoff of 150s.
      stale_at = DateTime.utc_now() |> DateTime.add(-11 * 15, :second)

      {:ok, pid} = WSConnStateStub.start(%WSConn{lastblock_at: stale_at})
      assert WSConn.stale?(pid, Chains.Anvil)
    end

    test "uses the chain's expected_block_intervall, not a fixed threshold" do
      # Oasis uses 6s intervals; 11 intervals = 66s is past the 60s cutoff,
      # but only 11s on Anvil where the cutoff is 150s.
      oasis_stale_at = DateTime.utc_now() |> DateTime.add(-11 * 6, :second)

      {:ok, oasis_pid} = WSConnStateStub.start(%WSConn{lastblock_at: oasis_stale_at})
      assert WSConn.stale?(oasis_pid, Chains.OasisSapphire)

      # Anvil cutoff is 150s; 11s is fresh on Anvil.
      fresh_at = DateTime.utc_now() |> DateTime.add(-11, :second)

      {:ok, anvil_pid} = WSConnStateStub.start(%WSConn{lastblock_at: fresh_at})
      refute WSConn.stale?(anvil_pid, Chains.Anvil)
    end

    test "is false for a process that is not a WSConn" do
      pid = spawn(fn -> receive do: (:stop -> :ok) end)

      try do
        refute WSConn.stale?(pid, Chains.Anvil)
      after
        send(pid, :stop)
      end
    end

    test "is false for a WSConn that has never observed a block" do
      # `lastblock_at` is nil until the first newHeads frame arrives. A
      # handshake-only connection must not be classified as stale.
      {:ok, pid} = WSConnStateStub.start(%WSConn{lastblock_at: nil})
      refute WSConn.stale?(pid, Chains.Anvil)
    end

    test "is false for a dead pid" do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
      refute WSConn.stale?(pid, Chains.Anvil)
    end
  end
end
