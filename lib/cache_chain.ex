defmodule CacheChain do
  defstruct [:a, :b]

  def new(a, b) do
    %__MODULE__{a: a, b: b}
  end

  def put(cache, key, value) do
    %CacheChain{cache | a: RemoteChain.Cache.put(cache.a, key, value)}
  end

  def get(cache, key) do
    case RemoteChain.Cache.get(cache.a, key) do
      nil ->
        value = RemoteChain.Cache.get(cache.b, key)

        if value != nil do
          RemoteChain.Cache.put(cache.a, key, value)
        end

        value

      value ->
        # We only put something into the second cache if it's queried a second time
        RemoteChain.Cache.put(cache.b, key, value)
        value
    end
  end

  def delete(cache, key) do
    %CacheChain{
      cache
      | a: RemoteChain.Cache.delete(cache.a, key),
        b: RemoteChain.Cache.delete(cache.b, key)
    }
  end
end
