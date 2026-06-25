# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Chains.EpochBlockTest do
  use ExUnit.Case, async: true

  alias MoonbeamEpochGroundTruth, as: GroundTruth

  describe "first_block_at_or_after_timestamp/4" do
    test "finds the first block whose timestamp reaches the target" do
      # 12s blocks until height 100, then 6s blocks (RT3000-style transition).
      blocktime = fn
        n when n <= 100 -> n * 12
        n -> 100 * 12 + (n - 100) * 6
      end

      assert Chains.first_block_at_or_after_timestamp(blocktime, 0, 1, 300) == 1
      assert Chains.first_block_at_or_after_timestamp(blocktime, 1200, 1, 300) == 100
      assert Chains.first_block_at_or_after_timestamp(blocktime, 1206, 1, 300) == 101
    end

    test "returns lo when the target is already met at the lower bound" do
      blocktime = fn n -> n * 6 end
      assert Chains.first_block_at_or_after_timestamp(blocktime, 60, 10, 100) == 10
    end
  end

  describe "epoch_block regression against Moonbeam ground truth" do
    test "production regression: epoch 675 first block is not the previously wrong height" do
      blocktime = GroundTruth.blocktime_fun()
      target = GroundTruth.target_timestamp(675)

      found =
        Chains.first_block_at_or_after_timestamp(
          blocktime,
          target,
          1,
          GroundTruth.max_block()
        )

      assert found == sample_block(675)
      refute found == GroundTruth.buggy_epoch_675_block()
    end

    test "timestamp_block extrapolation is not a reliable epoch boundary finder" do
      target = GroundTruth.target_timestamp(675)

      extrapolated =
        Chains.timestamp_block(6_593_037, 1_721_048_472, target, 12)

      assert extrapolated != sample_block(675)
    end

    test "binary search finds verified first-block-of-epoch boundaries" do
      blocktime = GroundTruth.blocktime_fun()
      max_block = GroundTruth.max_block()

      for sample <- GroundTruth.samples() do
        %{epoch: epoch, block: expected_block, timestamp: expected_ts} = sample
        target = GroundTruth.target_timestamp(epoch)

        found =
          Chains.first_block_at_or_after_timestamp(blocktime, target, 1, max_block)

        assert found == expected_block,
               "epoch #{epoch}: expected block #{expected_block}, got #{found}"

        assert blocktime.(found) >= target
        assert blocktime.(found - 1) < target
        assert blocktime.(found) == expected_ts
      end
    end

    test "timestamp epoch of the previous block is always epoch - 1" do
      blocktime = GroundTruth.blocktime_fun()
      duration = GroundTruth.epoch_duration()

      for %{epoch: epoch, block: block} <- GroundTruth.samples() do
        assert div(blocktime.(block), duration) == epoch
        assert div(blocktime.(block - 1), duration) == epoch - 1
      end
    end
  end

  defp sample_block(epoch) do
    %{block: block} = Enum.find(GroundTruth.samples(), &(&1.epoch == epoch))
    block
  end
end

defmodule Chains.MoonbeamEpochBlockIntegrationTest do
  use ExUnit.Case, async: false

  alias MoonbeamEpochGroundTruth, as: GroundTruth

  @moduletag :integration
  @tag timeout: 120_000

  setup_all do
    start_moonbeam_chain()
    :ok
  end

  setup do
    clear_epoch_block_cache()
    :ok
  end

  for sample <- MoonbeamEpochGroundTruth.samples() do
    @epoch sample.epoch
    @expected_block sample.block
    @prev_epoch sample.prev_epoch

    @tag timeout: 120_000
    test "epoch #{sample.epoch} first block is #{sample.block} on Moonbeam RPC" do
      chain = Chains.Moonbeam
      chain_id = chain.chain_id()
      epoch = @epoch
      expected_block = @expected_block

      block = Chains.epoch_block(chain, epoch)
      target_ts = GroundTruth.target_timestamp(epoch)

      assert block == expected_block

      if epoch == 675 do
        refute block == GroundTruth.buggy_epoch_675_block()
      end

      block_ts = RemoteChain.blocktime(chain_id, block)
      prev_ts = RemoteChain.blocktime(chain_id, block - 1)

      assert block_ts >= target_ts
      assert prev_ts < target_ts
      assert Chains.epoch(chain, block) == epoch
      assert Chains.epoch(chain, block - 1) == epoch - 1

      on_chain_epoch = Contract.Registry.epoch(chain_id, block)
      prev_on_chain_epoch = Contract.Registry.epoch(chain_id, block - 1)

      assert on_chain_epoch == epoch
      assert prev_on_chain_epoch == @prev_epoch
    end
  end

  defp start_moonbeam_chain do
    chain = Chains.Moonbeam

    if RemoteChain.RPCCache.whereis(chain) == nil do
      cache = %Exqlite.LRU{}
      {:ok, sup} = RemoteChain.Sup.start_link(chain, cache: cache)

      on_exit(fn ->
        if Process.alive?(sup), do: Supervisor.stop(sup, :normal)
      end)

      wait_for_peak(chain)
    end
  end

  defp wait_for_peak(chain, attempts \\ 30)

  defp wait_for_peak(_chain, 0),
    do: flunk("timed out waiting for Moonbeam peak block from RPC")

  defp wait_for_peak(chain, attempts) do
    case RemoteChain.peaknumber(chain.chain_id()) do
      peak when is_integer(peak) and peak > 0 ->
        :ok

      _ ->
        Process.sleep(1000)
        wait_for_peak(chain, attempts - 1)
    end
  end

  defp clear_epoch_block_cache do
    if :ets.info(:chains_epoch_block_cache) != :undefined do
      :ets.delete_all_objects(:chains_epoch_block_cache)
    end
  end
end
