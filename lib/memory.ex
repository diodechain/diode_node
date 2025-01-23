defmodule Memory do
  require Logger

  def report do
    m = :erlang.memory()

    Logger.info(
      "MEM " <>
        "rss: #{mb(check_rss())} " <>
        "beam_total: #{mb(m[:total])} procs: #{mb(m[:processes])}/#{mb(m[:processes] - m[:processes_used])} " <>
        "atoms: #{mb(m[:atom])}/#{mb(m[:atom] - m[:atom_used])} system: #{mb(m[:system])} binary: #{mb(m[:binary])} " <>
        "code: #{mb(m[:code])} ets: #{mb(m[:ets])}"
    )
  end

  def mb(num) do
    num = num / (1024 * 1024)
    "#{Float.round(num, 2)}MB"
  end

  def limit() do
    Diode.Config.get_int("MEMORY_LIMIT")
  end

  def check_rss() do
    with {:ok, rss} <- get_rss() do
      limit = limit()

      if rss > limit do
        Logger.error(
          "Memory limit nearly exceeded: #{mb(rss)} > #{mb(limit)}, trying to flush memory"
        )

        report()

        for pid <- :erlang.processes() do
          :erlang.garbage_collect(pid)
        end

        DetsPlus.sync(:remoterpc_cache)
        BinaryLRU.flush(:memory_cache)

        for pid <- :erlang.processes() do
          :erlang.garbage_collect(pid)
        end

        Process.sleep(30_000)
        {:ok, rss} = get_rss()
        Logger.info("Memory after flush: #{mb(rss)}")
        report()

        if rss > limit do
          Logger.error("Memory limit still exceeded: #{mb(rss)} > #{mb(limit)}, stopping")
          Process.sleep(10_000)
          System.halt(1)
        end
      end

      rss
    end
  end

  def get_memory_capacity() do
    case File.read("/proc/meminfo") do
      {:ok, data} ->
        case Regex.run(~r/MemTotal:\s+(\d+)\s+kB/, data) do
          [_, capacity_str] ->
            case Integer.parse(capacity_str) do
              {value, _} -> {:ok, value * 1024}
              _ -> {:error, :integer_parse_failed}
            end

          _ ->
            {:error, :parse_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_rss() do
    case File.read("/proc/self/status") do
      {:ok, data} ->
        # Find the position of "VmRSS:"
        case Regex.run(~r/VmRSS:\s+(\d+)\s+kB/, data) do
          [_, rss_str] ->
            case Integer.parse(rss_str) do
              {value, _} -> {:ok, value * 1024}
              _ -> {:error, :integer_parse_failed}
            end

          _ ->
            {:error, :parse_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
