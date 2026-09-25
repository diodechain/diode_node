defmodule Network.Sender do
  @moduledoc """
  Quality-Of-Service aware network sender. Wraps a socket and sends on
  multiple partitions. Small partitions are preferred over large ones.

  Partition ordering lives in `Network.Mux`.
  """
  use GenServer
  alias Network.Mux
  alias Network.Sender
  defstruct [:mux, :waiting, :relay]

  def new(socket) do
    {:ok, pid} = GenServer.start_link(__MODULE__, [socket], hibernate_after: 5_000)
    pid
  end

  def stop(q) do
    GenServer.stop(q, :normal)
  end

  def push_async(q, partition, data, trace) do
    GenServerDbg.call(q, {:push_async, partition, data, trace})
  end

  def push(q, partition, data) do
    GenServerDbg.call(q, {:push, partition, data}, :infinity)
  end

  def pop(q) do
    GenServerDbg.call(q, :pop)
  end

  def await(q) do
    GenServerDbg.call(q, :await, :infinity)
  end

  @impl true
  def handle_call({:push_async, partition, data, trace}, _from, state = %Sender{waiting: nil}) do
    {:reply, :ok, enqueue(state, partition, data, {:trace, trace})}
  end

  @impl true
  def handle_call({:push_async, _partition, data, trace}, _from, state = %Sender{waiting: from}) do
    GenServer.reply(from, data)
    Network.EdgeV2.trace(trace)
    {:reply, :ok, %Sender{state | waiting: nil}}
  end

  @impl true
  def handle_call({:push, partition, data}, from, state = %Sender{waiting: nil}) do
    {:noreply, enqueue(state, partition, data, from)}
  end

  @impl true
  def handle_call({:push, _partition, data}, _from, state = %Sender{waiting: from}) do
    GenServer.reply(from, data)
    {:reply, :ok, %Sender{state | waiting: nil}}
  end

  @impl true
  def handle_call(:pop, _from, state = %Sender{}) do
    case Mux.pop(state.mux) do
      {:empty, mux} ->
        {:reply, nil, %Sender{state | mux: mux}}

      {:ok, mux, data, meta} ->
        ack(meta)
        {:reply, data, %Sender{state | mux: mux}}
    end
  end

  @impl true
  def handle_call(:await, from, state) do
    do_await(from, state)
  end

  defp enqueue(state = %Sender{}, partition, data, meta) do
    %Sender{state | mux: Mux.enqueue(state.mux, partition, data, meta)}
  end

  defp ack(nil), do: :ok
  defp ack({:trace, trace}), do: Network.EdgeV2.trace(trace)
  defp ack(from), do: GenServer.reply(from, :ok)

  # Coalescing data frames into 64kb at least when available
  defp do_await(data \\ "", from, state = %Sender{waiting: nil}) do
    if Mux.partition_count(state.mux) > 0 and byte_size(data) < Mux.coalesce_limit() do
      {:reply, new_data, state} = handle_call(:pop, from, state)
      do_await(data <> new_data, from, state)
    else
      if byte_size(data) > 0 do
        {:reply, data, state}
      else
        {:noreply, %Sender{state | waiting: from}}
      end
    end
  end

  @impl true
  def terminate(reason, %Sender{relay: relay}) do
    if reason == :normal do
      Process.exit(relay, :kill)
    end

    reason
  end

  @impl true
  def init([socket]) do
    q = self()
    relay = spawn_link(__MODULE__, :relayer_loop, [q, socket])
    {:ok, %Sender{mux: Mux.new(), waiting: nil, relay: relay}}
  end

  def relayer_loop(q, socket) do
    case :ssl.send(socket, await(q)) do
      :ok -> relayer_loop(q, socket)
      other -> Process.exit(self(), other)
    end
  end
end
