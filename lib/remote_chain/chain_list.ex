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
    rpc = get(chain_id)["rpc"] || []

    Enum.map(rpc, fn rpc -> rpc["url"] end)
    |> Enum.concat(additional_endpoints)
    |> filter_endpoints(chain)
    |> Enum.group_by(fn endpoint ->
      cond do
        String.ends_with?(endpoint, "/http") -> :rpc
        String.ends_with?(endpoint, "/ws") -> :ws
        String.starts_with?(endpoint, "ws") -> :ws
        true -> :rpc
      end
    end)
  end

  def filter_endpoints(endpoints, chain) do
    endpoints
    |> Enum.uniq()
    |> Task.async_stream(fn url -> {url, test?(url, chain)} end,
      timeout: :infinity,
      max_concurrency: 10
    )
    |> Enum.to_list()
    |> Enum.filter(fn {:ok, {_, result}} -> result end)
    |> Enum.map(fn {:ok, {url, _}} -> url end)
    |> Enum.reject(fn url ->
      String.contains?(url, "pocket.network") or String.contains?(url, "curie.radiumblock.co")
    end)
  end

  def test?(url, chain) do
    Globals.cache(
      {__MODULE__, :test, url},
      fn ->
        Logger.info("Testing #{url} for #{chain}")
        ret = do_test?(url, chain)
        Logger.info("Tested #{url} for #{chain} and got #{ret}")
        ret
      end,
      :infinity
    )
  end

  def do_test?("ws" <> _ = ws_endpoint, chain) do
    pid = RemoteChain.WSConn.start(self(), chain, ws_endpoint)

    ret =
      if :ok ==
           RemoteChain.WSConn.send_request(
             pid,
             %{
               "jsonrpc" => "2.0",
               "id" => 99,
               "method" => "eth_chainId",
               "params" => []
             }
             |> Poison.encode!(),
             10_000
           ) do
        receive do
          {:response, _ws_url, %{"id" => 99, "result" => _chain_id}} ->
            true

          {:DOWN, _ref, :process, ^pid, _reason} ->
            false
        after
          3_000 ->
            false
        end
      else
        false
      end

    RemoteChain.WSConn.close(pid)
    ret
  after
    false
  end

  def do_test?(url, _chain) do
    case RemoteChain.HTTP.rpc(url, "eth_chainId", []) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @loaded_key {__MODULE__, :loaded}

  def get(chain_id) do
    key = cache_key(chain_id)

    case Globals.get(key) do
      nil ->
        Globals.locked({__MODULE__, :load_chains}, fn ->
          ensure_loaded()
          Globals.get(key)
        end)

      chain ->
        chain
    end
  end

  defp cache_key(chain_id), do: {__MODULE__, chain_id}

  defp ensure_loaded() do
    if Globals.get(@loaded_key) != true do
      refresh_chains()
      Globals.put(@loaded_key, true)
    end
  end

  defp refresh_chains() do
    file_path()
    |> File.read!()
    |> Jason.decode!()
    |> Map.new(fn %{"chainId" => id} = chain -> {id, chain} end)
    |> Enum.each(fn {id, chain} ->
      Globals.put(cache_key(id), chain)
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

    # Just ensure it's valid JSON
    {:ok, _chains} = Jason.decode(json)
    File.write!(Diode.data_dir("chains.json"), json)
    refresh_chains()
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
