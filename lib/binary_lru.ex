defmodule BinaryLRU do
  defstruct [:max_size, :key_queue, :current_size, :ets_table]
  use GenServer

  defmodule Handle do
    defstruct [:pid, :ets_table]
  end

  alias __MODULE__.Handle

  def start_link(opts \\ []) do
    max_memory_size = Keyword.fetch!(opts, :max_memory_size)

    gen_opts =
      (opts ++ [hibernate_after: 5_000])
      |> Keyword.take([:name, :hibernate_after])

    GenServer.start_link(__MODULE__, [max_memory_size], gen_opts)
  end

  def new(max_memory_size) do
    {:ok, pid} = start_link(max_memory_size: max_memory_size)
    handle(pid)
  end

  def handle(pid) do
    GenServer.call(pid, :handle)
  end

  def memory_size(%Handle{pid: pid}) do
    GenServer.call(pid, :memory_size)
  end

  def size(%Handle{pid: pid}) do
    GenServer.call(pid, :size)
  end

  def insert(lru, key, value), do: put(lru, key, value)

  def put(%Handle{} = handle, key, value) when is_binary(value) do
    do_put(handle, key, <<0>> <> value)
    value
  end

  def put(%Handle{} = handle, key, value) do
    do_put(handle, key, <<1>> <> :erlang.term_to_binary(value))
    value
  end

  def delete(%Handle{pid: pid}, key) do
    GenServer.cast(pid, {:delete, key})
  end

  def fetch(%Handle{} = lru, key, fun) do
    :global.trans({{__MODULE__, key}, self()}, fn ->
      get(lru, key) || put(lru, key, fun.())
    end)
  end

  def get(%Handle{ets_table: ets_table}, key) do
    case :ets.lookup(ets_table, key) do
      [{^key, data}] ->
        case :zlib.unzip(data) do
          <<0, data::binary>> -> data
          <<1, data::binary>> -> :erlang.binary_to_term(data)
        end

      _ ->
        nil
    end
  end

  @impl GenServer
  def init([max_size]) do
    table = :ets.new(__MODULE__, [:set, :public])

    {:ok,
     %BinaryLRU{max_size: max_size, key_queue: :queue.new(), current_size: 0, ets_table: table}}
  end

  @impl GenServer
  def handle_call(:handle, _from, state) do
    {:reply, %Handle{pid: self(), ets_table: state.ets_table}, state}
  end

  def handle_call(:memory_size, _from, state) do
    {:reply, state.current_size, state}
  end

  def handle_call(:size, _from, state) do
    {:reply, :ets.info(state.ets_table, :size), state}
  end

  @impl GenServer
  def handle_cast(
        {:put, key, size},
        state = %BinaryLRU{current_size: current_size, key_queue: key_queue}
      ) do
    current_size = current_size + size
    key_queue = :queue.in({key, size}, key_queue)

    state =
      %BinaryLRU{state | current_size: current_size, key_queue: key_queue}
      |> reduce()

    {:noreply, state}
  end

  def handle_cast(
        {:delete, key},
        state = %BinaryLRU{current_size: current_size, key_queue: key_queue}
      ) do
    with [{^key, data}] <- :ets.lookup(state.ets_table, key) do
      :ets.delete(state.ets_table, key)
      current_size = current_size - byte_size(data)
      key_queue = :queue.delete({key, byte_size(data)}, key_queue)
      {:noreply, %BinaryLRU{state | current_size: current_size, key_queue: key_queue}}
    else
      _other ->
        {:noreply, state}
    end
  end

  defp reduce(
         state = %BinaryLRU{
           current_size: current_size,
           key_queue: key_queue,
           max_size: max_size,
           ets_table: ets_table
         }
       )
       when current_size > max_size do
    {{:value, {key, size}}, queue} = :queue.out(key_queue)
    :ets.delete(ets_table, key)

    %BinaryLRU{state | current_size: current_size - size, key_queue: queue}
    |> reduce()
  end

  defp reduce(state), do: state

  defp do_put(%Handle{pid: pid, ets_table: ets_table}, key, value) do
    data = :zlib.zip(value)

    if :ets.insert_new(ets_table, {key, data}) do
      GenServer.cast(pid, {:put, key, byte_size(data)})
    end
  end
end
