defmodule Chain.NodeProxy do
  @moduledoc """
  Manage websocket connections to the given chain rpc node
  """
  alias Chain.NodeProxy
  require Logger

  defstruct [:chain, :connections]

  def start_link(chain) do
    GenServer.start_link(__MODULE__, %NodeProxy{chain: chain, connections: %{}},
      name: {__MODULE__, chain}
    )
  end

  def init(state) do
    {:ok, ensure_connections(state)}
  end

  @security_level 2
  defp ensure_connections(state = %NodeProxy{chain: chain, connections: connections})
       when map_size(connections) < @security_level do
    urls = MapSet.new(chain.ws_endpoints())
    existing = MapSet.new(Map.keys(connections))
    new_urls = MapSet.difference(urls, existing)
    new_url = MapSet.to_list(new_urls) |> List.first()

    pid = Chain.WSConn.start(chain, new_url)
    Process.monitor(pid)
    state = %{state | connections: Map.put(connections, new_url, pid)}
    ensure_connections(state)
  end

  defp ensure_connections(state) do
    state
  end
end
