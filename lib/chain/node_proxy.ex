defmodule Chain.NodeProxy do
  @moduledoc """
  Manage websocket connections to the given chain rpc node
  """
  use GenServer, restart: :permanent
  alias Chain.NodeProxy
  require Logger

  defstruct [:chain, connections: %{}, req: 0, requests: %{}, lastblocks: %{}]

  def start_link(chain) do
    GenServer.start_link(__MODULE__, %NodeProxy{chain: chain, connections: %{}},
      name: {:global, {__MODULE__, chain}}
    )
  end

  @impl true
  def init(state) do
    {:ok, ensure_connections(state)}
  end

  def rpc(chain, method, params) do
    GenServer.call({:global, {__MODULE__, chain}}, {:rpc, method, params})
  end

  @impl true
  def handle_call({:rpc, method, params}, from, state) do
    conn = Enum.random(Map.values(state.connections))
    id = state.req + 1

    request =
      %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => method,
        "params" => params
      }
      |> Poison.encode!()

    WebSockex.cast(conn, {:send_request, request})
    {:noreply, %{state | req: id, requests: Map.put(state.requests, id, from)}}
  end

  @security_level 1
  @impl true
  def handle_info(
        {:new_block, ws_url, block_number},
        state = %NodeProxy{chain: chain, lastblocks: lastblocks}
      ) do
    lastblocks = Map.put(lastblocks, ws_url, block_number)

    if Enum.count(lastblocks, fn {_, block} -> block == block_number end) >= @security_level do
      Chain.RPCCache.set_block_number(chain, block_number)
    end

    {:noreply, %{state | lastblocks: lastblocks}}
  end

  def handle_info({:DOWN, _ref, :process, down_pid, _reason}, state) do
    connections =
      state.connections |> Enum.filter(fn {_, pid} -> pid != down_pid end) |> Map.new()

    {:noreply, ensure_connections(%{state | connections: connections})}
  end

  defp ensure_connections(state = %NodeProxy{chain: chain, connections: connections})
       when map_size(connections) < @security_level do
    urls = MapSet.new(chain.ws_endpoints())
    existing = MapSet.new(Map.keys(connections))
    new_urls = MapSet.difference(urls, existing)
    new_url = MapSet.to_list(new_urls) |> List.first()

    pid = Chain.WSConn.start(self(), chain, new_url)
    Process.monitor(pid)
    state = %{state | connections: Map.put(connections, new_url, pid)}
    ensure_connections(state)
  end

  defp ensure_connections(state) do
    state
  end
end
