defmodule Network.Mux do
  @moduledoc """
  Fair-queue of outbound frames for one edge socket.

  `Network.Sender` used to own this map inline. Frames are grouped by
  partition (`{:port, ref}` for `portsend`, plus the RPC partition).
  `pop/1` always takes the partition whose queued term has the smaller
  `:erts_debug.flat_size/1`. `coalesce/2` concatenates pops up to 64KB
  for one `:ssl.send/2`.

  The client scheduler is `DiodeClient.Mux`. Same shortest-queue idea,
  different weight and backpressure. See that module for merge options.
  Keeping a pure `enqueue` / `pop` / `coalesce` here is option 1: the
  GenServer only does socket IO and ack replies.

  Known stress behavior (covered by `test/network/mux_test.exs`):

    * `flat_size` does not count refc binary bytes. One 15MB chunk looks
      smaller than a handful of sub-64-byte frames, so the large transfer
      is preferred and the small one stalls.
    * Equal weights do not share. `Enum.min/3` picks one partition,
      that pop makes it strictly lighter, and it is drained to
      completion before the other port runs. Two simultaneous
      transfers do not interleave.
    * `enqueue/4` appends with `++`. A multi-megabyte download that
      outruns the socket copies the whole queue on every chunk.
    * There is no byte cap. Two simultaneous downloads buffer without
      bound while the shorter queue is served exclusively.
  """

  @coalesce_limit 64_000

  defstruct partitions: %{}

  def new, do: %__MODULE__{}

  def coalesce_limit, do: @coalesce_limit

  @doc "Queue `frame` on `partition`, remembering `meta` for the matching pop."
  def enqueue(mux = %__MODULE__{partitions: partitions}, partition, frame, meta)
      when is_binary(frame) do
    partitions =
      Map.update(partitions, partition, {[frame], [meta]}, fn {queue, metas} ->
        {queue ++ [frame], metas ++ [meta]}
      end)

    %{mux | partitions: partitions}
  end

  @doc """
  Pop the lightest partition.

  Returns `{:empty, mux}` or `{:ok, mux, frame, meta}`.
  """
  def pop(mux = %__MODULE__{partitions: partitions}) do
    case pick(partitions) do
      nil ->
        {:empty, mux}

      {partition, {[frame | queue], [meta | metas]}} ->
        partitions = store(partitions, partition, queue, metas)
        {:ok, %{mux | partitions: partitions}, frame, meta}
    end
  end

  @doc """
  Pop and concatenate until `limit` bytes or the queue is empty.

  Returns `{mux, binary, metas}`.
  """
  def coalesce(mux, limit \\ @coalesce_limit) do
    do_coalesce(mux, limit, [], [])
  end

  def queued_frames(%__MODULE__{partitions: partitions}, partition) do
    case Map.get(partitions, partition) do
      nil -> []
      {queue, _metas} -> queue
    end
  end

  def partition_count(%__MODULE__{partitions: partitions}), do: map_size(partitions)

  defp do_coalesce(mux, limit, frames, metas) do
    size = IO.iodata_length(frames)

    if partition_count(mux) > 0 and size < limit do
      {:ok, mux, frame, meta} = pop(mux)
      do_coalesce(mux, limit, [frames, frame], [meta | metas])
    else
      {mux, IO.iodata_to_binary(frames), Enum.reverse(metas)}
    end
  end

  defp store(partitions, partition, [], []) do
    Map.delete(partitions, partition)
  end

  defp store(partitions, partition, queue, metas) do
    Map.put(partitions, partition, {queue, metas})
  end

  defp pick(partitions) do
    Enum.min(partitions, &lighter?/2, fn -> nil end)
  end

  defp lighter?({_, {frames_a, _}}, {_, {frames_b, _}}) do
    weight(frames_a) < weight(frames_b)
  end

  defp weight(frames), do: :erts_debug.flat_size(frames)
end
