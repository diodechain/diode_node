defmodule Network.MuxTest do
  use ExUnit.Case, async: true

  alias Network.Mux
  alias Network.Sender

  defp enqueue_all(mux, partition, frames) do
    Enum.reduce(frames, mux, fn frame, mux ->
      Mux.enqueue(mux, partition, frame, partition)
    end)
  end

  defp pop_metas(mux, n) do
    Enum.map_reduce(1..n, mux, fn _, mux ->
      {:ok, mux, _frame, meta} = Mux.pop(mux)
      {meta, mux}
    end)
  end

  describe "partition priority" do
    test "equal depth does not alternate; one partition is drained before the other" do
      mux =
        Mux.new()
        |> enqueue_all(:port_b, repeated(3, 1000))
        |> enqueue_all(:port_a, repeated(3, 1000))

      {metas, _} = pop_metas(mux, 6)
      assert metas == [:port_a, :port_a, :port_a, :port_b, :port_b, :port_b]
    end

    test "one refc bulk chunk outranks many small frames (flat_size ignores payload bytes)" do
      # 15MB-style chunk. flat_size counts the list cell and the binary
      # reference, not the 200KB. Twenty 1-byte frames weigh more, so the
      # bulk port is sent first and the small port waits.
      bulk = :binary.copy(<<1>>, 200_000)
      small = repeated(20, 1)

      mux =
        Mux.new()
        |> Mux.enqueue(:bulk, bulk, :bulk)
        |> enqueue_all(:small, small)

      {:ok, mux, frame, :bulk} = Mux.pop(mux)
      assert frame == bulk

      {metas, _} = pop_metas(mux, 20)
      assert metas == List.duplicate(:small, 20)
    end

    test "the shorter queue is served exclusively until depths match" do
      mux =
        Mux.new()
        |> enqueue_all(:deep, repeated(10, 8_000))
        |> enqueue_all(:shallow, repeated(2, 8_000))

      {metas, mux} = pop_metas(mux, 2)
      assert metas == [:shallow, :shallow]
      {:ok, _mux, _frame, :deep} = Mux.pop(mux)
    end

    test "a late small port preempts a port that already buffered a large transfer" do
      mux = enqueue_all(Mux.new(), :download_a, repeated(50, 16_000))
      mux = Mux.enqueue(mux, :download_b, <<0::size(16_000 * 8)>>, :download_b)

      {:ok, _, _, :download_b} = Mux.pop(mux)
    end
  end

  describe "coalesce" do
    test "packs frames from both ports into one 64KB socket write" do
      mux =
        Mux.new()
        |> enqueue_all(:port_a, repeated(40, 1_000))
        |> enqueue_all(:port_b, repeated(40, 1_000))

      {mux, blob, metas} = Mux.coalesce(mux)
      assert byte_size(blob) >= Mux.coalesce_limit()
      assert byte_size(blob) < Mux.coalesce_limit() + 1_000
      assert :port_a in metas and :port_b in metas
      assert Mux.queued_frames(mux, :port_a) == []
      assert Mux.queued_frames(mux, :port_b) != []
      assert Mux.partition_count(mux) == 1
    end

    test "returns empty when nothing is queued" do
      assert Mux.coalesce(Mux.new()) == {Mux.new(), "", []}
    end

    test "preserves order inside one partition" do
      frames = for n <- 1..5, do: <<n>>

      mux = enqueue_all(Mux.new(), :only, frames)
      {_, blob, metas} = Mux.coalesce(mux)
      assert blob == IO.iodata_to_binary(frames)
      assert metas == List.duplicate(:only, 5)
    end
  end

  describe "stress" do
    test "two deep ports buffer without a byte cap" do
      frames = repeated(100, 16_000)

      mux =
        Mux.new()
        |> enqueue_all(:download_a, frames)
        |> enqueue_all(:download_b, frames)

      assert length(Mux.queued_frames(mux, :download_a)) == 100
      assert length(Mux.queued_frames(mux, :download_b)) == 100
      assert Mux.partition_count(mux) == 2
    end

    test "enqueue keeps order on a long single-port queue" do
      frames = for n <- 1..300, do: <<n::16>>
      mux = enqueue_all(Mux.new(), :port, frames)
      assert Mux.queued_frames(mux, :port) == frames
    end

    test "pop deletes a partition once it is empty and leaves the other" do
      mux =
        Mux.new()
        |> Mux.enqueue(:gone, <<1>>, :gone)
        |> Mux.enqueue(:stay, <<2>>, :stay)

      {:ok, mux, <<2>>, :stay} = Mux.pop(mux)
      assert Mux.queued_frames(mux, :stay) == []
      assert Mux.queued_frames(mux, :gone) == [<<1>>]
      assert Mux.partition_count(mux) == 1
    end
  end

  describe "sender idle bypass" do
    test "a push while the writer is waiting skips the queue and the partition" do
      tag = make_ref()
      from = {self(), tag}

      state = %Sender{
        mux: Mux.new() |> Mux.enqueue(:queued, <<9>>, :queued),
        waiting: from,
        relay: self()
      }

      assert {:reply, :ok, %{waiting: nil} = state} =
               Sender.handle_call(
                 {:push_async, :racer, <<1, 2, 3>>, nil},
                 {self(), make_ref()},
                 state
               )

      assert_received {^tag, <<1, 2, 3>>}
      assert Mux.queued_frames(state.mux, :queued) == [<<9>>]
      assert Mux.queued_frames(state.mux, :racer) == []
    end

    test "await coalesces queued partitions and does not wait" do
      tag_a = make_ref()
      tag_b = make_ref()

      mux =
        Mux.new()
        |> Mux.enqueue(:port_a, <<0::size(1000 * 8)>>, {self(), tag_a})
        |> Mux.enqueue(:port_b, <<1::size(1000 * 8)>>, {self(), tag_b})

      state = %Sender{mux: mux, waiting: nil, relay: self()}

      assert {:reply, blob, %{waiting: nil}} =
               Sender.handle_call(:await, {self(), make_ref()}, state)

      assert byte_size(blob) == 2_000
      assert_receive {^tag_a, :ok}
      assert_receive {^tag_b, :ok}
    end
  end

  defp repeated(n, size), do: for(_ <- 1..n, do: <<0::size(size * 8)>>)
end
