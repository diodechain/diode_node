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
    test "equal quantum-sized frames alternate in insertion order" do
      q = Mux.quantum()

      mux =
        Mux.new()
        |> enqueue_all(:port_b, repeated(3, q))
        |> enqueue_all(:port_a, repeated(3, q))

      {metas, _} = pop_metas(mux, 6)
      assert metas == [:port_b, :port_a, :port_b, :port_a, :port_b, :port_a]
    end

    test "a large refc chunk does not outrank frames already queued" do
      bulk = :binary.copy(<<1>>, 200_000)
      small = repeated(20, 1)

      mux =
        Mux.new()
        |> enqueue_all(:small, small)
        |> Mux.enqueue(:bulk, bulk, :bulk)

      {metas, _} = pop_metas(mux, 21)
      assert metas == List.duplicate(:small, 20) ++ [:bulk]
    end

    test "the shorter queue waits its turn instead of being served exclusively" do
      mux =
        Mux.new()
        |> enqueue_all(:deep, repeated(10, 8_000))
        |> enqueue_all(:shallow, repeated(2, 8_000))

      {metas, _} = pop_metas(mux, 10)
      assert hd(metas) == :deep
      assert :shallow in metas
      assert Enum.take(metas, 2) != [:shallow, :shallow]
    end

    test "a late small port does not preempt a port already in the ring" do
      mux = enqueue_all(Mux.new(), :download_a, repeated(8, 16_000))
      mux = Mux.enqueue(mux, :download_b, <<0::size(16_000 * 8)>>, :download_b)

      {metas, _} = pop_metas(mux, 5)
      assert Enum.take(metas, 4) == List.duplicate(:download_a, 4)
      assert Enum.at(metas, 4) == :download_b
    end

    test "small frames from two ports share bandwidth within a quantum" do
      mux =
        Mux.new()
        |> enqueue_all(:port_a, repeated(200, 1_000))
        |> enqueue_all(:port_b, repeated(200, 1_000))

      {metas, _} = pop_metas(mux, 400)

      bursts =
        metas
        |> Enum.chunk_by(& &1)
        |> Enum.map(&(length(&1) * 1_000))

      assert Enum.max(bursts) <= Mux.quantum()
      assert Enum.count(metas, &(&1 == :port_a)) == 200
      assert Enum.count(metas, &(&1 == :port_b)) == 200
    end
  end

  describe "coalesce" do
    test "packs a quantum from the first port, then the next, into one 64KB write" do
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

      {:ok, mux, <<1>>, :gone} = Mux.pop(mux)
      assert Mux.queued_frames(mux, :gone) == []
      assert Mux.queued_frames(mux, :stay) == [<<2>>]
      assert Mux.partition_count(mux) == 1
    end
  end

  describe "sender idle bypass" do
    test "a push while the writer is waiting enters the queue behind what is already waiting" do
      tag = make_ref()
      from = {self(), tag}

      queued = make_ref()

      state = %Sender{
        mux: Mux.new() |> Mux.enqueue(:queued, <<9>>, {self(), queued}),
        waiting: from,
        relay: self()
      }

      assert {:reply, :ok, %{waiting: nil} = state} =
               Sender.handle_call(
                 {:push_async, :racer, <<1, 2, 3>>, nil},
                 {self(), make_ref()},
                 state
               )

      assert_received {^tag, <<9>>}
      assert_received {^queued, :ok}
      assert Mux.queued_frames(state.mux, :racer) == [<<1, 2, 3>>]
      assert Mux.queued_frames(state.mux, :queued) == []
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

  describe "performance" do
    test "enqueue and pop of many frames stays linear" do
      small = time_pop(2_000)
      large = time_pop(8_000)
      assert large < small * 10
      assert large < 1_000_000
    end

    test "one hundred partitions each pop once quickly" do
      mux =
        Enum.reduce(1..100, Mux.new(), fn n, mux ->
          Mux.enqueue(mux, n, <<n>>, n)
        end)

      {micro, metas} =
        :timer.tc(fn ->
          {metas, _} = pop_metas(mux, 100)
          metas
        end)

      assert metas == Enum.to_list(1..100)
      assert micro < 100_000
    end
  end

  defp time_pop(n) do
    frames = repeated(n, 64)

    {micro, _} =
      :timer.tc(fn ->
        mux =
          Mux.new()
          |> enqueue_all(:a, frames)
          |> enqueue_all(:b, frames)

        pop_metas(mux, n * 2)
      end)

    micro
  end

  defp repeated(n, size), do: for(_ <- 1..n, do: <<0::size(size * 8)>>)
end
