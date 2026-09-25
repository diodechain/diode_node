defmodule Network.Mux do
  @moduledoc """
  Round-robin queue of outbound frames for one edge socket.

  Frames are grouped by partition (`{:port, ref}` for `portsend`, plus
  the RPC partition). `pop/1` serves the current partition until it has
  sent `quantum/0` bytes (64KB), then rotates. Weight is the payload
  byte size. `coalesce/2` concatenates pops up to 64KB for one
  `:ssl.send/2`.

  The client scheduler is `DiodeClient.Mux`.
  """

  @coalesce_limit 64_000
  @quantum 64_000

  defstruct partitions: %{}, ring: [], turn: 0

  def new, do: %__MODULE__{}

  def coalesce_limit, do: @coalesce_limit

  def quantum, do: @quantum

  @doc "Queue `frame` on `partition`, remembering `meta` for the matching pop."
  def enqueue(mux = %__MODULE__{}, partition, frame, meta) when is_binary(frame) do
    partitions = mux.partitions
    ring = if Map.has_key?(partitions, partition), do: mux.ring, else: mux.ring ++ [partition]

    slot =
      case Map.get(partitions, partition) do
        nil -> {:queue.new(), :queue.new()}
        existing -> existing
      end

    {frames, metas} = slot
    slot = {:queue.in(frame, frames), :queue.in(meta, metas)}
    %{mux | partitions: Map.put(partitions, partition, slot), ring: ring}
  end

  @doc """
  Pop one frame from the partition whose turn it is.

  Returns `{:empty, mux}` or `{:ok, mux, frame, meta}`.
  """
  def pop(mux = %__MODULE__{ring: []}), do: {:empty, %{mux | turn: 0}}

  def pop(mux = %__MODULE__{ring: [partition | rest], turn: turn}) do
    cond do
      empty_slot?(mux, partition) ->
        pop(drop_partition(mux, partition))

      turn >= @quantum ->
        pop(%{mux | ring: rest ++ [partition], turn: 0})

      true ->
        take_frame(mux, partition, rest)
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
      {frames, _metas} -> :queue.to_list(frames)
    end
  end

  def partition_count(%__MODULE__{partitions: partitions}), do: map_size(partitions)

  defp take_frame(mux, partition, rest) do
    {frames, metas} = Map.fetch!(mux.partitions, partition)
    {:value, next} = :queue.peek(frames)

    if mux.turn > 0 and mux.turn + byte_size(next) > @quantum do
      pop(%{mux | ring: rest ++ [partition], turn: 0})
    else
      emit(mux, partition, rest, frames, metas)
    end
  end

  defp emit(mux, partition, rest, frames, metas) do
    {{:value, frame}, frames} = :queue.out(frames)
    {{:value, meta}, metas} = :queue.out(metas)
    partitions = Map.put(mux.partitions, partition, {frames, metas})
    turn = mux.turn + byte_size(frame)
    mux = %{mux | partitions: partitions, turn: turn}

    mux =
      cond do
        empty_slot?(mux, partition) ->
          drop_partition(%{mux | ring: [partition | rest]}, partition)

        turn >= @quantum ->
          %{mux | ring: rest ++ [partition], turn: 0}

        true ->
          mux
      end

    {:ok, mux, frame, meta}
  end

  defp drop_partition(mux, partition) do
    %{
      mux
      | partitions: Map.delete(mux.partitions, partition),
        ring: Enum.reject(mux.ring, &(&1 == partition)),
        turn: 0
    }
  end

  defp empty_slot?(mux, partition) do
    case Map.get(mux.partitions, partition) do
      nil -> true
      {frames, _metas} -> :queue.is_empty(frames)
    end
  end

  defp do_coalesce(mux, limit, frames, metas) do
    size = IO.iodata_length(frames)

    if partition_count(mux) > 0 and size < limit do
      {:ok, mux, frame, meta} = pop(mux)
      do_coalesce(mux, limit, [frames, frame], [meta | metas])
    else
      {mux, IO.iodata_to_binary(frames), Enum.reverse(metas)}
    end
  end
end
