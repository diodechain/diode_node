defmodule RemoteChain.NonceProvider do
  use GenServer, restart: :permanent
  require Logger
  alias DiodeClient.{Base16, Wallet}
  alias RemoteChain.NonceProvider

  defstruct [:next_nonce, :fetched_nonce, :fetched_at, :chain]

  def start_link(chain) do
    GenServer.start_link(__MODULE__, chain, name: name(chain), hibernate_after: 5_000)
  end

  defp name(chain) do
    impl = RemoteChain.chainimpl(chain)
    {:global, {__MODULE__, impl}}
  end

  @impl true
  def init(chain) do
    RemoteChain.NodeProxy.subscribe_block(chain)
    {:ok, %__MODULE__{chain: chain}}
  end

  def nonce(chain) do
    GenServer.call(name(chain), :nonce)
  end

  @impl true
  def handle_call(:nonce, _from, state = %NonceProvider{next_nonce: nil, chain: chain}) do
    # We keep track of the next nonce in case there are multiple transactions which can
    # be sent in the same block.
    nonce = fetch_nonce(chain)

    {:reply, nonce,
     %NonceProvider{
       state
       | next_nonce: nonce + 1,
         fetched_nonce: nonce,
         fetched_at: System.system_time(:second)
     }}
  end

  def handle_call(:nonce, _from, state = %NonceProvider{next_nonce: next_nonce}) do
    # This is the case where we already have a next nonce, so we just return it and increment it.
    {:reply, next_nonce, %NonceProvider{state | next_nonce: next_nonce + 1}}
  end

  @impl true
  def handle_info(
        {_chain, :block_number, _block_number},
        state = %NonceProvider{next_nonce: next_nonce, chain: chain}
      ) do
    # If nonce prediction is currently active, we compare with the chain value to ensure
    # that the nonce counting stays in sync.
    if next_nonce != nil do
      Debouncer.immediate(__MODULE__, fn -> fetch_nonce(chain) end)
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:new_nonce, new_fetched_nonce, new_fetched_at},
        state = %NonceProvider{
          next_nonce: next_nonce,
          fetched_nonce: fetched_nonce,
          fetched_at: fetched_at
        }
      ) do
    fetched_nonce = max(fetched_nonce, new_fetched_nonce)
    fetched_at = if new_fetched_nonce != fetched_nonce, do: new_fetched_at, else: fetched_at
    state = %NonceProvider{state | fetched_nonce: fetched_nonce, fetched_at: fetched_at}

    cond do
      next_nonce == nil ->
        {:noreply, state}

      fetched_nonce > next_nonce ->
        Logger.warning(
          "RTX next_nonce (#{next_nonce}) is smaller than fetched_nonce (#{fetched_nonce}), probably extern TX - resetting"
        )

        {:noreply, %NonceProvider{state | next_nonce: nil}}

      fetched_nonce == next_nonce ->
        # We don't need prediction anymore, so we reset the next nonce.
        {:noreply, %NonceProvider{state | next_nonce: nil}}

      System.system_time(:second) - fetched_at > 30 ->
        Logger.warning(
          "RTX next_nonce (#{next_nonce}) is != fetched_nonce (#{fetched_nonce}) and it's not moving - resetting"
        )

        {:noreply, %NonceProvider{state | next_nonce: nil}}

      true ->
        {:noreply, state}
    end
  end

  def fetch_nonce(chain) do
    nonce =
      RemoteChain.RPCCache.get_transaction_count(
        chain,
        Wallet.base16(CallPermitAdapter.wallet()),
        "latest"
      )
      |> Base16.decode_int()

    GenServer.cast(name(chain), {:new_nonce, nonce, System.system_time(:second)})
    nonce
  end
end
