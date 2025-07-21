defmodule Globals do
  use GenServer
  require Logger

  defstruct [
    # subscribers is a map of {key => {pid => monitor_ref}}
    subscribers: %{},
    # refreshers is a map of {key => fun}
    refreshers: %{},
    # dependencies is a map of {key => [key]}
    dependencies: %{},
    # monitors is a map of {pid => {monitor_ref, [key]}}
    monitors: %{},
    # waiting is a map of {key => [{generation, pid, timer}]}
    waiting: %{},
    # Generation tracks update_await() call origin times. So that a update_await() call
    # can only be responded to using an update that has be started at or after the update_await() call,
    # but not from an previous update that is still running.
    generation: 0
  ]

  @timeout 30_000

  def start_link(_args) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__, hibernate_after: 5000)
  end

  @impl true
  def init([]) do
    :ets.new(__MODULE__, [:public, :named_table, read_concurrency: true])
    {:ok, %Globals{}}
  end

  def get(key, default \\ nil) do
    case :ets.lookup(__MODULE__, key) do
      [] -> default
      [{_, value}] -> value
    end
  end

  def get_g(key, default \\ nil) do
    call({:get_g, key, default})
  end

  def update_await(key, opts \\ []) do
    timeout = Keyword.get(opts, :timeout)
    call({:update_await, key}, timeout)
  end

  def await(key, timeout \\ :infinity) do
    get(key) || call({:await, key}, timeout)
  end

  def pop(key, default \\ nil) do
    call({:pop, key, default})
  end

  def incr(key, default \\ 0) do
    call({:incr, key, default})
  end

  @doc """
    put sets the new value and returns the OLD value
  """
  def put(key, value, src_gen \\ nil) do
    old = get(key, nil)
    :ets.insert(__MODULE__, {key, value})
    GenServer.cast(__MODULE__, {:put, key, old, value, src_gen})
    old
  end

  @doc """
    pushes a new value to all subscribers without setting it

    returns the new value
  """
  def push(key, value) do
    call({:push, key, value})
  end

  @doc """
    set sets the new value and returns the NEW value
  """
  def set(key, value) do
    put(key, value)
    value
  end

  def update(key) do
    Debouncer.immediate(
      {__MODULE__, key},
      fn ->
        {fun, gen} = call({:update, key})
        if fun != nil, do: do_update(key, fun, gen)
      end,
      1000
    )
  end

  def update(key, fun) do
    Debouncer.immediate(
      {__MODULE__, key},
      fn -> do_update(key, fun) end,
      1000
    )
  end

  defp do_update(key, fun, gen \\ nil) do
    {old, other_gen} = get_g(key)
    gen = gen || other_gen

    new =
      case fun do
        {module, fun, args} -> apply(module, fun, args)
        no_args when is_function(fun, 0) -> no_args.()
        one_arg when is_function(fun, 1) -> one_arg.(old)
      end

    old2 = put(key, new, gen)

    if old2 != old do
      Logger.warning("update conflict in ~p", [key])
    end

    new
  end

  @doc """
    Register a key and function to be called when the key is updated.
    If the function is not provided, the key must be a tuple of {module, function, args}.

    # Examples

    iex> Globals.register({Module, :update, []})
    iex> Globals.register({Module, :update, []}, depends_on: [{OtherModule, :update, []}])
    iex> Globals.register(:name, {Module, :update, []}, changes: [{OtherModule, :update, []}])
  """
  def register(key, fun \\ nil, opts \\ []) do
    {opts, fun} =
      if opts == [] and is_list(fun) do
        {fun, nil}
      else
        {opts, fun}
      end

    fun =
      if fun == nil do
        if not is_tuple(key) and tuple_size(key) != 3 do
          raise "Need to provide a function for key: #{inspect(key)} or key must be a tuple of {module, function, args}"
        end

        key
      else
        fun
      end

    if !call({:register, key, fun, opts}) do
      update(key, fun)
    end

    if Keyword.get(opts, :await, false) do
      await(key)
    end
  end

  def subscribe(keys, whom \\ self()) do
    List.wrap(keys)
    |> Enum.each(fn key -> GenServer.cast(__MODULE__, {:subscribe, whom, key}) end)

    :ok
  end

  def unsubscribe(keys, whom \\ self()) do
    call({:unsubscribe, keys, whom})
  end

  defp do_unsubscribe(g = %Globals{subscribers: subs, monitors: mons}, :all, whom) do
    {ref, remove_keys} = Map.get(mons, whom)
    Process.demonitor(ref)
    mons = Map.delete(mons, whom)

    subs = do_unsubscribe_key_subs(subs, Enum.to_list(remove_keys), whom)
    %Globals{g | subscribers: subs, monitors: mons}
  end

  defp do_unsubscribe(g = %Globals{subscribers: subs, monitors: mons}, remove_keys, whom) do
    {ref, keys} = Map.get(mons, whom)
    new_keys = Enum.reduce(remove_keys, keys, &MapSet.delete(&2, &1))

    mons =
      if MapSet.size(new_keys) == 0 do
        Process.demonitor(ref)
        Map.delete(mons, whom)
      else
        Map.put(mons, whom, new_keys)
      end

    subs = do_unsubscribe_key_subs(subs, Enum.to_list(remove_keys), whom)
    %Globals{g | subscribers: subs, monitors: mons}
  end

  defp do_unsubscribe_key_subs(subs, [], _whom) do
    subs
  end

  defp do_unsubscribe_key_subs(subs, [key | rest], whom) do
    {_ref, key_subs} = Map.get(subs, key, %{}) |> Map.pop(whom)

    if map_size(key_subs) == 0 do
      Map.delete(subs, key)
    else
      Map.put(subs, key, key_subs)
    end
    |> do_unsubscribe_key_subs(rest, whom)
  end

  @impl true
  def handle_cast({:put, key, old, value, src_gen}, g = %Globals{generation: generation}) do
    g = %Globals{g | generation: generation + 1}
    {:noreply, publish(g, key, value, old, src_gen)}
  end

  def handle_cast({:subscribe, whom, key}, g = %Globals{subscribers: subs, monitors: mons})
      when is_pid(whom) do
    {ref, keys} =
      case Map.get(mons, whom) do
        nil -> {Process.monitor(whom), MapSet.new([key])}
        {ref, keys} -> {ref, MapSet.put(keys, key)}
      end

    mons = Map.put(mons, whom, {ref, keys})

    key_subs =
      Map.get(subs, key, %{})
      |> Map.put_new(whom, ref)

    subs = Map.put(subs, key, key_subs)
    {:noreply, %Globals{g | subscribers: subs, monitors: mons}}
  end

  def handle_cast({:subscribe, mfa, key}, g = %Globals{subscribers: subs}) do
    key_subs =
      Map.get(subs, key, %{})
      |> Map.put_new(mfa, mfa)

    subs = Map.put(subs, key, key_subs)
    {:noreply, %Globals{g | subscribers: subs}}
  end

  @impl true
  def handle_call({:unsubscribe, keys, whom}, _from, g = %Globals{}) do
    {:reply, :ok, do_unsubscribe(g, keys, whom)}
  end

  def handle_call(
        {:register, key, fun, opts},
        _from,
        g = %Globals{refreshers: refs, dependencies: deps}
      ) do
    depends_on = List.wrap(Keyword.get(opts, :depends_on, []))
    changes = List.wrap(Keyword.get(opts, :changes, []))

    deps =
      Enum.reduce(depends_on, deps, fn dep, deps ->
        Map.put(deps, dep, Map.get(deps, dep, []) ++ [key])
      end)

    deps =
      Enum.reduce(changes, deps, fn dst, deps ->
        Map.put(deps, key, Map.get(deps, key, []) ++ [dst])
      end)

    {:reply, Map.has_key?(refs, key),
     %Globals{g | dependencies: deps, refreshers: Map.put(refs, key, fun)}}
  end

  def handle_call(
        {:await, key},
        from,
        g = %Globals{waiting: waiting, refreshers: refs}
      ) do
    case get(key) do
      nil ->
        timer = Process.send_after(self(), {:timeout, key, from}, @timeout - 2000)

        waiting =
          Map.update(waiting, key, [{nil, from, timer}], fn pids ->
            [{nil, from, timer} | pids]
          end)

        if Map.has_key?(refs, key) do
          update(key)
        else
          Logger.info("Awaiting undefined key: #{inspect(key)}")
        end

        {:noreply, %Globals{g | waiting: waiting}}

      value ->
        {:reply, value, g}
    end
  end

  def handle_call({:pop, key, default}, _from, g = %Globals{generation: generation}) do
    value = get(key, default)
    :ets.delete(__MODULE__, key)
    {:reply, value, %Globals{g | generation: generation + 1}}
  end

  def handle_call({:incr, key, default}, _from, g = %Globals{generation: generation}) do
    prev_value = get(key, default)
    value = prev_value + 1
    :ets.insert(__MODULE__, {key, value})
    g = %Globals{g | generation: generation + 1}
    {:reply, prev_value, publish(g, key, value, nil, nil)}
  end

  def handle_call({:push, key, value}, _from, g = %Globals{generation: generation}) do
    :ets.delete(__MODULE__, key)
    g = %Globals{g | generation: generation + 1}
    {:reply, value, publish(g, key, value, nil, nil)}
  end

  def handle_call({:get_g, key, default}, _from, g = %Globals{generation: generation}) do
    value = get(key, default)
    {:reply, {value, generation}, g}
  end

  def handle_call({:update_await, key}, from, g = %Globals{waiting: waiting, generation: gen}) do
    timer = Process.send_after(self(), {:timeout, key, from}, @timeout - 2000)

    waiting =
      Map.update(waiting, key, [{gen, from, timer}], fn pids -> [{gen, from, timer} | pids] end)

    update(key)
    {:noreply, %Globals{g | waiting: waiting}}
  end

  def handle_call({:update, key}, _from, g = %Globals{refreshers: refs, generation: gen}) do
    {:reply, {Map.get(refs, key), gen}, g}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, g = %Globals{}) do
    {:noreply, do_unsubscribe(g, :all, pid)}
  end

  def handle_info({:timeout, key, from}, g = %Globals{waiting: waiting}) do
    froms = Map.get(waiting, key, [])
    zombie? = Enum.all?(froms, fn {_gen, f, _timer} -> f != from end)
    pid = Debouncer.worker({__MODULE__, key})

    if pid == nil do
      Logger.error("Timeout waiting for #{inspect(key)} (zombie=#{zombie?}) - No worker found")
    else
      Logger.error("Timeout waiting for #{inspect(key)} (zombie=#{zombie?}) - \
          Worker stuck in: #{inspect(Profiler.stacktrace(pid))}")
    end

    {:noreply, g}
  end

  defp call(what, timeout \\ @timeout) do
    GenServer.call(__MODULE__, what, timeout || @timeout)
  end

  defp publish(
         g = %Globals{subscribers: subs, waiting: waiting, dependencies: deps},
         key,
         value,
         old,
         src_gen
       ) do
    if old == nil or value != old do
      pids = Map.keys(Map.get(subs, key, %{}))

      # This does effect `RemoteDrive.publish()` because the drive_dir is part of the value,
      # using only the key would silently debounce remove values for different drives
      Debouncer.immediate(
        {__MODULE__, :publish, key, value},
        fn ->
          {pids, mfas} = Enum.split_with(pids, &is_pid/1)

          for pid <- pids do
            send(pid, {:update, key, value})
          end

          for fun <- mfas do
            case fun do
              {module, fun, args} -> apply(module, fun, args)
              no_args when is_function(fun, 0) -> no_args.()
              one_arg when is_function(fun, 1) -> one_arg.(value)
              two_arg when is_function(fun, 2) -> two_arg.(key, value)
            end
          end
        end,
        500
      )

      for dep_key <- Map.get(deps, key, []) do
        update(dep_key)
      end
    end

    list =
      Map.get(waiting, key, [])
      |> Enum.reject(fn {gen, from, timer} ->
        if src_gen == nil or gen == nil or gen <= src_gen do
          Process.cancel_timer(timer)
          GenServer.reply(from, value)
          true
        end
      end)

    waiting = if list == [], do: Map.delete(waiting, key), else: Map.put(waiting, key, list)
    %Globals{g | waiting: waiting}
  end

  def locked(lockname, fun) do
    :global.trans({lockname, self()}, fun)
  end

  def cache(key, fun, timeout \\ 5_000)

  def cache(key, fun, :infinity) do
    now = System.system_time(:millisecond)

    case get(key) do
      nil ->
        value = fun.()
        put(key, {value, now})
        value

      {value, _timestamp} ->
        value
    end
  end

  def cache(key, fun, timeout) do
    now = System.system_time(:millisecond)

    case get(key) do
      nil ->
        value = fun.()
        put(key, {value, now})
        value

      {value, timestamp} ->
        if now - timestamp > timeout do
          value = fun.()
          put(key, {value, now})
          value
        else
          value
        end
    end
  end
end
