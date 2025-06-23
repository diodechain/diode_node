defprotocol RemoteChain.Cache do
  def get(cache, key)
  def put(cache, key, value)
  def delete(cache, key)
end

defimpl RemoteChain.Cache, for: Lru do
  def get(cache, key), do: Lru.get(cache, key)
  def put(cache, key, value), do: Lru.insert(cache, key, value)
  def delete(cache, key), do: Lru.insert(cache, key, nil)
end

defimpl RemoteChain.Cache, for: DetsPlus do
  def get(cache, key) do
    case DetsPlus.lookup(cache, key) do
      [{^key, value}] -> value
      _ -> nil
    end
  end

  def put(cache, key, value) do
    DetsPlus.insert(cache, {key, value})
    cache
  end

  def delete(cache, key) do
    DetsPlus.delete(cache, key)
    cache
  end
end

defimpl RemoteChain.Cache, for: DetsPlus.LRU do
  def get(cache, key) do
    DetsPlus.LRU.get(cache, key)
  end

  def put(cache, key, value) do
    DetsPlus.LRU.put(cache, key, value)
    cache
  end

  def delete(cache, key) do
    DetsPlus.LRU.delete(cache, key)
    cache
  end
end

defimpl RemoteChain.Cache, for: DetsPlus.HashLRU do
  def get(cache, key) do
    DetsPlus.HashLRU.get(cache, key)
  end

  def put(cache, key, value) do
    DetsPlus.HashLRU.put(cache, key, value)
    cache
  end

  def delete(cache, key) do
    DetsPlus.HashLRU.delete(cache, key)
    cache
  end
end

defimpl RemoteChain.Cache, for: BinaryLRU.Handle do
  def get(cache, key) do
    BinaryLRU.get(cache, key)
  end

  def put(cache, key, value) do
    BinaryLRU.put(cache, key, value)
    cache
  end

  def delete(cache, key) do
    BinaryLRU.delete(cache, key)
    cache
  end
end

defimpl RemoteChain.Cache, for: Exqlite.LRU do
  def get(_cache, key) do
    Exqlite.LRU.get(key)
  end

  def put(cache, key, value) do
    Exqlite.LRU.set(key, value)
    cache
  end

  def delete(cache, key) do
    Exqlite.LRU.delete(key)
    cache
  end
end

defimpl RemoteChain.Cache, for: CacheChain do
  def get(cache, key) do
    CacheChain.get(cache, key)
  end

  def put(cache, key, value) do
    CacheChain.put(cache, key, value)
    cache
  end

  def delete(cache, key) do
    CacheChain.delete(cache, key)
    cache
  end
end
