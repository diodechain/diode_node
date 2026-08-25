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
    ports =
      if ports == [] do
        ""
      else
        "?ports=#{Enum.join(ports, ",")}"
      end

    case Req.get("#{monitor_url()}/ip/self#{ports}",
           retry: false,
           max_redirects: 0,
           receive_timeout: 60_000,
           decode_body: false
         ) do
      {:ok, %{status: 200, body: body}} ->
        Logger.info("check_connectivity: #{body}")
        ret = %{"ip" => ip, "ports" => _ports} = Poison.decode!(body)
        Diode.Config.set("HOST", ip)
        ret

      {:ok, %{status: status}} ->
        Logger.error("check_connectivity: HTTP #{status}")
        {:error, {:http_status, status}}

      {:error, reason} ->
        Logger.error("check_connectivity: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Overridable so tests can point connectivity checks at a local mock.
  defp monitor_url() do
    Application.get_env(:diode, :monitor_url, "https://monitor.testnet.diode.io")
  end
end
