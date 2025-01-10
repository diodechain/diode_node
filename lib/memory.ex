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

  def check_rss() do
    with {:ok, rss} <- get_rss() do
      limit = Diode.Config.get_int("MEMORY_LIMIT")

      if rss > limit do
        Logger.error("Memory limit exceeded: #{mb(rss)} > #{mb(limit)}")
        Process.sleep(15_000)
        System.halt(1)
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
