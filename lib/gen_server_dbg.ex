defmodule GenServerDbg do
  def call(pid, msg, timeout \\ 5000) do
    try do
      GenServer.call(pid, msg, timeout)
    catch
      :exit, reason = {:timeout, _} ->
        Profiler.print_stacktrace(pid)
        exit(reason)
    end
  end
end
