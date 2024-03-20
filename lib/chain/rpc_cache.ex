# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Chain.RPCCache do
  use GenServer, restart: :permanent
  require Logger
  alias Chain.NodeProxy
  alias Chain.RPCCache

  defstruct [:chain, :lru, :block_number]

  def start_link(chain) do
    GenServer.start_link(__MODULE__, chain,
      name: {:global, {__MODULE__, chain}},
      hibernate_after: 5_000
    )
  end

  @impl true
  def init(chain) do
    {:ok, %__MODULE__{chain: chain, lru: Lru.new(1000), block_number: nil}}
  end

  def set_block_number(chain, block_number) do
    GenServer.cast({:global, {__MODULE__, chain}}, {:block_number, block_number})
  end

  def block_number(chain) do
    case GenServer.call({:global, {__MODULE__, chain}}, :block_number) do
      nil -> raise "no block_number yet"
      number -> number
    end
  end

  def get_block_by_number(chain, block \\ "latest", with_transactions \\ false) do
    block =
      if block == "latest" do
        block_number(chain)
      else
        block
      end

    get(chain, "eth_getBlockByNumber", [block, with_transactions])
  end

  def get_storage_at(chain, address, slot, block \\ "latest") do
    block =
      if block == "latest" do
        block_number(chain)
      else
        block
      end

    get(chain, "eth_getStorageAt", [address, slot, block])
  end

  def get(chain, method, args) do
    GenServer.call({:global, {__MODULE__, chain}}, {:get, method, args})
  end

  @impl true
  def handle_cast({:block_number, block_number}, state) do
    {:noreply, %RPCCache{state | block_number: block_number}}
  end

  @impl true
  def handle_call(:block_number, _from, state = %RPCCache{block_number: number}) do
    {:reply, number, state}
  end

  def handle_call({:get, method, args}, _from, state = %RPCCache{chain: chain, lru: lru}) do
    {lru, ret} = Lru.fetch(lru, {method, args}, fn -> NodeProxy.rpc!(chain, method, args) end)
    {:reply, ret, %RPCCache{state | lru: lru}}
  end
end
