defmodule Memory do
  require Logger

  def report do
    m = :erlang.memory()

    Logger.info(
      "MEM " <>
        "total: #{mb(m[:total])} procs: #{mb(m[:processes])}/#{mb(m[:processes] - m[:processes_used])} " <>
        "atoms: #{mb(m[:atom])}/#{mb(m[:atom] - m[:atom_used])} system: #{mb(m[:system])} binary: #{mb(m[:binary])} " <>
        "code: #{mb(m[:code])} ets: #{mb(m[:ets])}"
    )
  end

  def mb(num) do
    num = num / (1024 * 1024)
    "#{Float.round(num, 2)}MB"
  end
end
