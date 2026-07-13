defmodule RemoteChain.ChainListTest do
  use ExUnit.Case, async: false

  @chain_id 1
  @other_chain_id 56
  @loaded_key {RemoteChain.ChainList, :loaded}

  setup do
    on_exit(&clear_chain_cache/0)
    clear_chain_cache()
    :ok
  end

  test "get/1 initializes globals cache on first access" do
    key = cache_key(@chain_id)
    assert Globals.get(key) == nil

    chain = RemoteChain.ChainList.get(@chain_id)

    assert chain["chainId"] == @chain_id
    assert is_list(chain["rpc"])
    assert Globals.get(key) == chain
  end

  test "get/1 primes all chains when any chain id is missing" do
    assert Globals.get(cache_key(@chain_id)) == nil
    assert Globals.get(cache_key(@other_chain_id)) == nil

    RemoteChain.ChainList.get(@chain_id)

    assert Globals.get(cache_key(@other_chain_id))["chainId"] == @other_chain_id
  end

  test "get/1 uses separate globals keys per chain id" do
    chain1 = RemoteChain.ChainList.get(@chain_id)
    chain56 = RemoteChain.ChainList.get(@other_chain_id)

    assert Globals.get(cache_key(@chain_id)) == chain1
    assert Globals.get(cache_key(@other_chain_id)) == chain56
    assert chain1["chainId"] == @chain_id
    assert chain56["chainId"] == @other_chain_id
  end

  test "get/1 does not reload file for unknown chain ids" do
    assert RemoteChain.ChainList.get(9_999_999_999) == nil
    assert RemoteChain.ChainList.get(9_999_999_999) == nil
    assert Globals.get(@loaded_key) == true
  end

  test "get/1 prefers chains.json in data dir when present" do
    path = Diode.data_dir("chains.json")
    File.mkdir_p!(Path.dirname(path))

    custom_chain = %{
      "chainId" => 99_999,
      "name" => "custom-test-chain",
      "rpc" => [%{"url" => "https://example.invalid/rpc"}]
    }

    File.write!(path, Jason.encode!([custom_chain]))

    on_exit(fn ->
      File.rm(path)
      clear_chain_cache()
    end)

    assert RemoteChain.ChainList.get(99_999) == custom_chain
  end

  test "refresh_chains/1 updates cached chain ids without priming uncached entries" do
    chain = RemoteChain.ChainList.get(@chain_id)
    key = cache_key(@chain_id)
    uncached_chain_id = 9_999_999_998
    uncached_key = cache_key(uncached_chain_id)

    Globals.put(key, Map.put(chain, "name", "stale"))

    updated_chain = Map.put(chain, "name", "updated")
    uncached_chain = %{"chainId" => uncached_chain_id, "name" => "new", "rpc" => []}

    RemoteChain.ChainList.refresh_chains([updated_chain, uncached_chain])

    assert Globals.get(key)["name"] == "updated"
    assert Globals.get(uncached_key) == nil
  end

  defp cache_key(chain_id), do: {RemoteChain.ChainList, chain_id}

  defp clear_chain_cache() do
    Globals.pop(@loaded_key)

    Enum.each([@chain_id, @other_chain_id, 99_999], fn chain_id ->
      Globals.pop(cache_key(chain_id))
    end)
  end
end
