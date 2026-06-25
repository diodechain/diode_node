# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule MoonbeamEpochGroundTruth do
  @moduledoc """
  On-chain verified first-block-of-epoch boundaries for Moonbeam.

  Each sample was found by binary search on block timestamps against
  `epoch * 2_592_000`, then checked with `Registry.Epoch()` at `block` and
  `block - 1` via cast against a Moonbeam RPC endpoint.
  """

  @epoch_duration 2_592_000
  @genesis_timestamp 1_639_798_584

  # Block height returned on production before the binary-search fix (epoch 675).
  # On-chain `Registry.Epoch()` still reports 675 at this block, but block - 1 is
  # also epoch 675, so it is not the first block of the epoch.
  @buggy_epoch_675_block 11_348_331

  @samples [
    %{epoch: 667, block: 7_877_855, timestamp: 1_728_864_000, prev_epoch: 666},
    %{epoch: 668, block: 8_302_506, timestamp: 1_731_456_000, prev_epoch: 667},
    %{epoch: 669, block: 8_723_076, timestamp: 1_734_048_000, prev_epoch: 668},
    %{epoch: 670, block: 9_141_877, timestamp: 1_736_640_000, prev_epoch: 669},
    %{epoch: 674, block: 10_832_204, timestamp: 1_747_008_000, prev_epoch: 673},
    %{epoch: 675, block: 11_250_202, timestamp: 1_749_600_000, prev_epoch: 674},
    %{epoch: 676, block: 11_673_402, timestamp: 1_752_192_000, prev_epoch: 675},
    %{epoch: 680, block: 13_260_984, timestamp: 1_762_560_006, prev_epoch: 679},
    %{epoch: 685, block: 15_119_196, timestamp: 1_775_520_000, prev_epoch: 684},
    %{epoch: 686, block: 15_522_162, timestamp: 1_778_112_000, prev_epoch: 685},
    %{epoch: 687, block: 15_905_817, timestamp: 1_780_704_000, prev_epoch: 686}
  ]

  def epoch_duration, do: @epoch_duration
  def samples, do: @samples
  def buggy_epoch_675_block, do: @buggy_epoch_675_block
  def max_block, do: List.last(@samples).block

  def target_timestamp(epoch), do: epoch * @epoch_duration

  @doc """
  Piecewise-linear block timestamps from verified epoch-boundary anchors.

  Used by unit tests to exercise `Chains.first_block_at_or_after_timestamp/4`
  with realistic Moonbeam timing (including the RT3000 12s -> 6s transition)
  without live RPC.
  """
  def blocktime_fun do
    anchors = build_anchors()

    fn block ->
      blocktime_at(block, anchors)
    end
  end

  defp build_anchors do
    genesis = {1, @genesis_timestamp}
    epoch_anchors = Enum.map(@samples, fn %{block: block, timestamp: ts} -> {block, ts} end)
    [genesis | epoch_anchors]
  end

  defp blocktime_at(block, [{anchor_block, anchor_ts} | _] = _anchors)
       when block <= anchor_block do
    extrapolate_before(block, anchor_block, anchor_ts, pre_rt3000_interval())
  end

  defp blocktime_at(block, anchors) do
    case Enum.chunk_every(anchors, 2, 1, :discard) do
      [] ->
        raise "no anchors"

      pairs ->
        case Enum.find(pairs, fn [{_b0, _}, {b1, _}] -> block <= b1 end) do
          [{b0, ts0}, {b1, ts1}] ->
            interpolate(block, b0, ts0, b1, ts1)

          nil ->
            {b_last, ts_last} = List.last(anchors)
            ts_last + (block - b_last) * post_rt3000_interval()
        end
    end
  end

  defp extrapolate_before(block, anchor_block, anchor_ts, interval) do
    anchor_ts - (anchor_block - block) * interval
  end

  defp interpolate(block, b0, ts0, b1, ts1) do
    ts0 + div((ts1 - ts0) * (block - b0), b1 - b0)
  end

  defp pre_rt3000_interval, do: 12
  defp post_rt3000_interval, do: 6
end
