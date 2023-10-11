defmodule BlockProcess do
  alias Chain.Block
  require Logger

  @moduledoc """
    Warpper around a Blocks Chain state to avoid copying the data from process to process. At the current
    block size of 44mb on average copying the full merkleized tree takes ~50ms. Sending a message to the BlockProcess
    instead just takes a couple of micros.
  """

  defmodule Worker do
    defstruct [:hash, :timeout]

    def init(hash) when is_binary(hash) do
      block =
        Stats.tc(:sql_block_by_hash, fn ->
          Model.ChainSql.block_by_hash(hash)
        end)

      # IO.puts("block: #{Block.number(block)}")

      %Worker{hash: hash, timeout: 10_000}
      |> do_init(block)
      |> work()
    end

    def init(%Block{} = block) do
      state =
        %Worker{hash: Block.hash(block), timeout: 60_000}
        |> do_init(block)

      Chain.Block.state_tree(block)
      work(state)
    end

    defp do_init(state = %Worker{hash: hash}, block) do
      Process.put(__MODULE__, hash)
      Process.put({__MODULE__, :block, hash}, block)

      if block == nil do
        Logger.debug("empty block #{Base16.encode(hash)}")
      end

      # IO.puts("starting block: #{Block.number(block)}")

      state
    end

    def is_worker(hash) when is_binary(hash) do
      hash() == hash
    end

    def is_worker() do
      hash() != nil
    end

    def hash() do
      Process.get(__MODULE__, nil)
    end

    def block() do
      Process.get({__MODULE__, :block, hash()}, nil)
    end

    def with_block(block_hash, fun) do
      key = {__MODULE__, :block, block_hash}

      # IO.inspect(Profiler.stacktrace())
      case Process.get(key, nil) do
        nil ->
          block =
            Stats.tc(:sql_block_by_hash, fn ->
              Model.ChainSql.block_by_hash(block_hash)
            end)

          Process.put(key, block)
          fun.(block)

        block ->
          fun.(block)
      end
    end

    defp work(state = %Worker{hash: hash, timeout: timeout}) do
      receive do
        # IO.puts("stopped worker #{Block.number(block)}")
        {:with_block, _block_num, fun, pid} ->
          block = block()

          ret =
            try do
              {:ok, fun.(block)}
            rescue
              e -> {:error, e, __STACKTRACE__}
            end

          case block do
            nil ->
              send(pid, {fun, ret})

            _block ->
              # Order is important we want to ensure the ready signal
              # arrives at the BlockProcess before the next `get_worker` call
              GenServer.cast(BlockProcess, {:i_am_ready, hash, self()})
              send(pid, {fun, ret})
              work(state)
          end

        :stop ->
          # IO.puts("stopping block: #{Block.number(block)}")
          :ok
      after
        timeout ->
          nr = Chain.blocknumber(hash)
          peak = Chain.peak()

          cond do
            # keep the top 10 blocks always online...
            BlockProcess.has_cache() and nr > peak - 10 ->
              work(state)

            not GenServer.call(BlockProcess, {:can_i_stop?, hash, self()}, :infinity) ->
              work(state)

            true ->
              # IO.puts("stopping block: #{Chain.blocknumber(hash)} peak: #{Chain.peak()}")
              :ok
          end
      end
    end
  end

  use GenServer
  defstruct [:ready, :busy, :waiting, :mons, :queue]

  def start_link() do
    GenServer.start_link(
      __MODULE__,
      %BlockProcess{ready: %{}, mons: %{}, queue: :queue.new(), waiting: %{}, busy: %{}},
      name: __MODULE__
    )
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call(
        {:get_worker, block_hash},
        from,
        state = %BlockProcess{
          ready: ready,
          busy: busy,
          waiting: waiting,
          mons: mons,
          queue: queue
        }
      ) do
    case Map.get(ready, block_hash, []) do
      [] ->
        case Map.get(busy, block_hash, []) do
          [] ->
            {pid, mon} = spawn_monitor(fn -> Worker.init(block_hash) end)
            busy = map_add_value(busy, block_hash, pid)
            {:reply, pid, %BlockProcess{state | busy: busy, mons: Map.put(mons, mon, block_hash)}}

          busy_blocks ->
            block_waits = map_get(waiting, block_hash)

            if length(block_waits) > length(busy_blocks) do
              {pid, mon} = spawn_monitor(fn -> Worker.init(block_hash) end)
              busy = map_add_value(busy, block_hash, pid)

              {:reply, pid,
               %BlockProcess{state | busy: busy, mons: Map.put(mons, mon, block_hash)}}
            else
              waiting = map_add_value(waiting, block_hash, from)
              {:noreply, %BlockProcess{state | waiting: waiting}}
            end
        end

      [pid | rest] ->
        ready = map_put(ready, block_hash, rest)
        busy = map_add_value(busy, block_hash, pid)
        queue = queue_delete(queue, pid)
        {:reply, pid, %BlockProcess{state | ready: ready, queue: queue, busy: busy}}
    end
  end

  def handle_call(
        {:add_worker, block_pid, block_hash},
        _from,
        state = %BlockProcess{mons: mons, ready: ready}
      ) do
    mon = Process.monitor(block_pid)
    ready = map_add_value(ready, block_hash, block_pid)

    state =
      %BlockProcess{state | mons: Map.put(mons, mon, block_hash), ready: ready}
      |> queue_add(block_pid, block_hash)

    {:reply, block_pid, state}
  end

  def handle_call(
        {:can_i_stop?, block_hash, pid},
        _from,
        state = %BlockProcess{ready: ready, queue: queue}
      ) do
    if pid in map_get(ready, block_hash) do
      queue = queue_delete(queue, pid)
      ready = map_delete_value(ready, block_hash, pid)

      {:reply, true, %BlockProcess{state | ready: ready, queue: queue}}
    else
      {:reply, false, state}
    end
  end

  @impl true
  def handle_cast(
        {:i_am_ready, block_hash, pid},
        state = %BlockProcess{ready: ready, waiting: waiting, busy: busy}
      ) do
    case map_get(waiting, block_hash) do
      [from | rest] ->
        GenServer.reply(from, pid)
        {:noreply, %BlockProcess{state | waiting: map_put(waiting, block_hash, rest)}}

      [] ->
        ready = map_add_value(ready, block_hash, pid)
        busy = map_delete_value(busy, block_hash, pid)
        {:noreply, queue_add(%BlockProcess{state | ready: ready, busy: busy}, pid, block_hash)}
    end
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, remove_pid, reason},
        state = %BlockProcess{ready: ready, mons: mons, queue: queue}
      ) do
    remove_hash = Map.get(mons, ref)
    queue = queue_delete(queue, remove_pid)
    ready = map_delete_value(ready, remove_hash, remove_pid)
    mons = Map.delete(mons, ref)

    if reason != :normal do
      Logger.warn("block_proxy #{Base16.encode(remove_hash)} crashed for #{inspect(reason)}")
    end

    {:noreply, %BlockProcess{state | mons: mons, ready: ready, queue: queue}}
  end

  @queue_limit 100
  defp queue_add(state = %BlockProcess{queue: queue, ready: ready}, pid, hash) do
    if :queue.len(queue) > @queue_limit do
      {{:value, {remove_pid, remove_hash}}, queue} = :queue.out_r(queue)
      send(remove_pid, :stop)
      ready = map_delete_value(ready, remove_hash, remove_pid)
      %BlockProcess{state | ready: ready, queue: :queue.in_r({pid, hash}, queue)}
    else
      %BlockProcess{state | queue: :queue.in_r({pid, hash}, queue)}
    end
  end

  defp queue_delete(queue, pid) do
    :queue.delete_with(fn {tpid, _} -> tpid == pid end, queue)
  end

  defp map_put(map, key, []), do: Map.delete(map, key)
  defp map_put(map, key, value), do: Map.put(map, key, value)
  defp map_get(map, key), do: Map.get(map, key, [])

  defp map_delete_value(map, key, value) do
    map_put(map, key, List.delete(map_get(map, key), value))
  end

  defp map_add_value(map, key, value) do
    Map.update(map, key, [value], fn rest -> [value | rest] end)
  end

  def fetch(block_ref, methods) when is_list(methods) do
    with_block(block_ref, fn block ->
      Enum.map(methods, fn method -> apply(Block, method, [block]) end)
    end)
  end

  def with_account_tree(block_ref, account_id, fun) do
    with_block(block_ref, fn block -> fun.(Block.account_tree(block, account_id)) end)
  end

  def with_account(block_ref, account_id, fun) do
    with_state(block_ref, fn state -> fun.(Chain.State.account(state, account_id)) end)
  end

  def with_state(block_ref, fun) do
    with_block(block_ref, fn block -> fun.(Block.state(block)) end)
  end

  def with_block(<<block_hash::binary-size(32)>>, fun) do
    if Chain.block_by_hash?(block_hash) do
      if Worker.is_worker() and Worker.hash() == block_hash do
        fun.(Worker.block())
      else
        get_worker(block_hash)
        |> do_with_block(fun)
      end
    else
      with_block(nil, fun)
    end
  end

  def with_block(%Block{} = block, fun), do: fun.(block)
  def with_block("latest", fun), do: with_block(Chain.peak(), fun)
  def with_block("pending", fun), do: Chain.Worker.with_candidate(fun)
  def with_block("earliest", fun), do: with_block(0, fun)
  def with_block(nil, fun), do: fun.(nil)
  def with_block(num, fun) when is_integer(num), do: with_block(Chain.blockhash(num), fun)

  def with_block(<<"0x", _rest::binary>> = ref, fun) do
    if byte_size(ref) >= 66 do
      # assuming it's a block hash
      with_block(Base16.decode(ref), fun)
    else
      # assuming it's a block index
      with_block(Base16.decode_int(ref), fun)
    end
  end

  defp do_with_block(block_pid, fun) when is_pid(block_pid) do
    ref = Process.monitor(block_pid)
    send(block_pid, {:with_block, :pid, fun, self()})

    receive do
      {:DOWN, ^ref, :process, _pid, reason} ->
        raise "failed with_block() for #{inspect(reason)}"

      {^fun, {:ok, ret}} ->
        Process.demonitor(ref, [:flush])
        ret

      {^fun, {:error, error, trace}} ->
        Process.demonitor(ref, [:flush])
        Kernel.reraise(error, trace)
    end
  end

  defp get_worker(block_hash) do
    case GenServer.call(__MODULE__, {:get_worker, block_hash}, :infinity) do
      pid when is_pid(pid) ->
        pid
    end
  end

  def start_block(%Block{} = block) do
    pid = spawn(fn -> Worker.init(block) end)
    ^pid = GenServer.call(__MODULE__, {:add_worker, pid, Block.hash(block)}, :infinity)
    Block.hash(block)
  end

  def maybe_cache(hash, key, fun) do
    if Worker.is_worker(hash) do
      case Process.get({Worker, key}, nil) do
        nil ->
          value = fun.()
          Process.put({Worker, key}, value)
          value

        value ->
          value
      end
    else
      fun.()
    end
  end

  def has_cache() do
    [:state] in Process.get_keys()
  end
end
