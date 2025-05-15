defmodule RemoteChain.NonceProvider do
  use GenServer, restart: :permanent
  require Logger
  alias DiodeClient.{Base16, Wallet}
  alias RemoteChain.NonceProvider

  defstruct [
    :next_nonce,
    :fetched_nonce,
    :fetched_at,
    :chain,
    :pending_nonce,
    :waiting_nonce_requests,
    :pending_nonce_ref
  ]

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
    {:ok, %__MODULE__{chain: chain, waiting_nonce_requests: []}}
  end

  def peek_nonce(chain) do
    GenServer.call(name(chain), :peek_nonce) || fetch_nonce(chain)
  end

  def nonce(chain) do
    GenServer.call(name(chain), :nonce)
  end

  def confirm_nonce(chain, nonce) do
    GenServer.cast(name(chain), {:confirm_nonce, nonce})
  end

  def cancel_nonce(chain, nonce) do
    GenServer.cast(name(chain), {:cancel_nonce, nonce})
  end

  def has_next_nonce?(chain) do
    GenServer.call(name(chain), :has_next_nonce?)
  end

  @impl true
  def handle_call(:has_next_nonce?, _from, state = %NonceProvider{next_nonce: next_nonce}) do
    {:reply, next_nonce != nil, state}
  end

  def handle_call(:peek_nonce, _from, state = %NonceProvider{next_nonce: next_nonce}) do
    {:reply, next_nonce, state}
  end

  def handle_call(:nonce, from, state = %NonceProvider{waiting_nonce_requests: reqs}) do
    reqs = reqs ++ [from]
    GenServer.cast(self(), :update_request)
    {:noreply, %NonceProvider{state | waiting_nonce_requests: reqs}}
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

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        state = %NonceProvider{pending_nonce_ref: ref}
      ) do
    {:noreply, %NonceProvider{state | pending_nonce: nil, pending_nonce_ref: nil}}
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

  def handle_cast(:update_request, state = %NonceProvider{waiting_nonce_requests: []}) do
    {:noreply, state}
  end

  def handle_cast(
        :update_request,
        state = %NonceProvider{waiting_nonce_requests: [{pid, _tag} = next | reqs]}
      ) do
    {nonce, state} = do_get_nonce(state)
    GenServer.reply(next, nonce)
    ref = Process.monitor(pid)

    {:noreply,
     %NonceProvider{
       state
       | waiting_nonce_requests: reqs,
         pending_nonce: nonce,
         pending_nonce_ref: ref
     }}
  end

  def handle_cast(
        {:confirm_nonce, pending_nonce},
        state = %NonceProvider{pending_nonce: pending_nonce, pending_nonce_ref: ref}
      ) do
    Process.demonitor(ref, [:flush])
    GenServer.cast(self(), :update_request)
    {:noreply, %NonceProvider{state | pending_nonce: nil, pending_nonce_ref: nil}}
  end

  def handle_cast(
        {:cancel_nonce, pending_nonce},
        state = %NonceProvider{
          pending_nonce: pending_nonce,
          pending_nonce_ref: ref,
          next_nonce: next_nonce
        }
      ) do
    Process.demonitor(ref, [:flush])
    GenServer.cast(self(), :update_request)

    {:noreply,
     %NonceProvider{
       state
       | pending_nonce: nil,
         pending_nonce_ref: nil,
         next_nonce: next_nonce - 1
     }}
  end

  defp do_get_nonce(state = %NonceProvider{next_nonce: nil, chain: chain}) do
    # We keep track of the next nonce in case there are multiple transactions which can
    # be sent in the same block.
    nonce = fetch_nonce(chain)

    {nonce,
     %NonceProvider{
       state
       | next_nonce: nonce + 1,
         fetched_nonce: nonce,
         fetched_at: System.system_time(:second)
     }}
  end

  defp do_get_nonce(state = %NonceProvider{next_nonce: next_nonce}) do
    # This is the case where we already have a next nonce, so we just return it and increment it.
    {next_nonce, %NonceProvider{state | next_nonce: next_nonce + 1}}
  end

  def fetch_nonce(chain) do
    nonce =
      RemoteChain.RPCCache.get_transaction_count(
        chain,
        Wallet.base16(Diode.wallet()),
        "latest"
      )
      |> Base16.decode_int()

    GenServer.cast(name(chain), {:new_nonce, nonce, System.system_time(:second)})
    nonce
  end
end
