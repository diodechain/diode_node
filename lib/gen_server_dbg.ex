defmodule GenServerDbg do
  require Logger

  def call(pid, msg, timeout \\ 5000) do
    try do
      GenServer.call(pid, msg, timeout)
    catch
      :exit, reason = {:timeout, _} ->
        self_trace = Profiler.format_stacktrace(self())
        pid_trace = Profiler.format_stacktrace(pid)

        Logger.error(
          "Timeout calling #{inspect(pid)} #{inspect(msg)}\nSelf: #{self_trace}\nPid: #{pid_trace}"
        )

        exit(reason)
    end
  end
end
