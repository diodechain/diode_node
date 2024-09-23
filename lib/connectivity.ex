defmodule Connectivity do
  alias Model.Ets
  require Logger

  def check_connectivity() do
    do_check_connectivity([])
  end

  def check_connectivity(:all) do
    do_check_connectivity([Diode.peer2_port() | Diode.edge2_ports()])
  end

  def query_connectivity() do
    Debouncer.immediate(
      :query_connectivity,
      fn ->
        timestamp = System.os_time(:second)
        Ets.put_new(Diode, :query_connectivity, %{timestamp: timestamp, status: "pending"})

        status =
          case check_connectivity(:all) do
            {:error, reason} -> "failed: #{inspect(reason)}"
            ret -> ret
          end

        Ets.put(Diode, :query_connectivity, %{timestamp: timestamp, status: status})
      end,
      10_000
    )

    Ets.lookup(Diode, :query_connectivity, fn ->
      %{timestamp: System.os_time(:second), status: "started"}
    end)
  end

  defp do_check_connectivity(ports) do
    case HTTPoison.get(
           "https://monitor.testnet.diode.io/ip/self?ports=#{Enum.join(ports, ",")}",
           [],
           recv_timeout: 60_000,
           timeout: 60_000
         ) do
      {:ok, %{status_code: 200, body: body}} ->
        Logger.info("check_connectivity: #{body}")
        ret = %{"ip" => ip, "ports" => _ports} = Poison.decode!(body)
        Diode.Config.set("HOST", ip)
        ret

      {:error, reason} ->
        Logger.error("check_connectivity: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
