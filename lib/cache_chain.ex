defmodule CacheChain do
  defstruct [:a, :b]

  def new(a, b) do
    %__MODULE__{a: a, b: b}
  end

  def put(cache, key, value) do
    %CacheChain{
      a: RemoteChain.Cache.put(cache.a, key, value),
      b: RemoteChain.Cache.put(cache.b, key, value)
    }
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
        value
    end
  end
end
