defmodule RemoteChain.ChainList do
  require Logger

  def rpc_endpoints(chain, additional_endpoints \\ []) do
    endpoints(chain, additional_endpoints)[:rpc]
    |> check_endpoints(chain)
  end

  def ws_endpoints(chain, additional_endpoints \\ []) do
    endpoints(chain, additional_endpoints)[:ws]
    |> check_endpoints(chain)
  end

  defp check_endpoints(endpoints, chain) do
    if endpoints == nil or endpoints == [] do
      Logger.error("No endpoints found for chain #{chain}")
    end

    endpoints
  end

  def endpoints(chain, additional_endpoints \\ []) do
    chain_id = RemoteChain.chainimpl(chain).chain_id()
    rpc = all()[chain_id]["rpc"] || []

    Enum.map(rpc, fn rpc -> rpc["url"] end)
    |> Enum.concat(additional_endpoints)
    |> filter_endpoints()
    |> Enum.group_by(fn endpoint ->
      cond do
        String.ends_with?(endpoint, "/http") -> :rpc
        String.ends_with?(endpoint, "/ws") -> :ws
        String.starts_with?(endpoint, "ws") -> :ws
        true -> :rpc
      end
    end)
  end

  def filter_endpoints(endpoints) do
    endpoints
    |> Enum.uniq()
    |> Task.async_stream(fn url -> {url, test?(url)} end, timeout: :infinity, max_concurrency: 10)
    |> Enum.to_list()
    |> Enum.filter(fn {:ok, {_, result}} -> result end)
    |> Enum.map(fn {:ok, {url, _}} -> url end)
    |> Enum.reject(fn url ->
      String.contains?(url, "pocket.network") or String.contains?(url, "curie.radiumblock.co")
    end)
  end

  def test?("ws" <> _url) do
    true
  end

  def test?(url) do
    Globals.cache(
      {__MODULE__, :test, url},
      fn ->
        RemoteChain.HTTP.rpc(url, "eth_chainId", [])
      end,
      :infinity
    )
    |> case do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  def all() do
    Globals.cache({__MODULE__, :all}, fn ->
      File.read!(file_path())
      |> Jason.decode!()
      |> Enum.map(fn %{"chainId" => id} = chain -> {id, chain} end)
      |> Map.new()
    end)
  end

  def update() do
    case File.stat(Diode.data_dir("chains.json"), time: :posix) do
      {:error, _} ->
        download_update()

      {:ok, %{mtime: mtime}} ->
        if mtime < System.os_time(:second) - :timer.hours(24) * 7 do
          download_update()
        end
    end
  end

  defp download_update() do
    json =
      HTTPoison.get!("https://chainlist.org/rpcs.json")
      |> Map.get(:body)

    {:ok, _valid} = Jason.decode(json)
    File.write!(Diode.data_dir("chains.json"), json)
    Globals.put({__MODULE__, :all}, nil)
    :updated
  end

  def file_path() do
    updated_file = Diode.data_dir("chains.json")

    if File.exists?(updated_file) do
      updated_file
    else
      Path.join([:code.priv_dir(:diode), "rpcs.json"])
    end
  end
end
