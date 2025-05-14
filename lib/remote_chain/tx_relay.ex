# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule RemoteChain.TxRelay do
  @moduledoc """
  Repeat transactions to the chain
  """
  use GenServer, restart: :permanent
  alias RemoteChain.TxRelay
  alias DiodeClient.{Base16, Transaction}
  require Logger

  defstruct [:chain, :txlist]

  defmodule Tx do
    defstruct [:metatx, :payload, :sender]
  end

  def start_link(chain) do
    GenServer.start_link(__MODULE__, %TxRelay{chain: chain, txlist: []}, name: name(chain))
  end

  @impl true
  def init(state) do
    :timer.send_interval(2_000, :ping)
    {:ok, state}
  end

  def pending_sender_tx?(chain, sender) do
    GenServer.call(name(chain), {:pending_sender_tx?, sender})
  end

  def keep_alive(chain, metatx, payload, sender) do
    GenServer.cast(name(chain), %Tx{metatx: metatx, payload: payload, sender: sender})
  end

  @impl true
  def handle_call({:pending_sender_tx?, sender}, _from, %TxRelay{txlist: txlist} = state) do
    {:reply, Enum.any?(txlist, fn tx -> tx.sender == sender end), state}
  end

  @impl true
  def handle_cast(tx = %Tx{}, %TxRelay{txlist: txlist} = state) do
    {:noreply, %TxRelay{state | txlist: [tx | txlist]}}
  end

  @impl true
  def handle_info(:ping, %TxRelay{txlist: []} = state) do
    {:noreply, state}
  end

  def handle_info(:ping, %TxRelay{txlist: txlist, chain: chain} = state) do
    gas_price = RemoteChain.RPC.gas_price(chain) |> Base16.decode_int()
    nonce = RemoteChain.NonceProvider.fetch_nonce(chain)
    txlist = process(txlist, nonce, gas_price, state)
    {:noreply, %TxRelay{state | txlist: txlist}}
  end

  def process([], _nonce, _gasprice, _state) do
    []
  end

  def process(
        [
          %Tx{
            metatx: metatx = %Transaction{nonce: tx_nonce, gasPrice: tx_gas_price},
            payload: payload
          }
          | rest
        ],
        nonce,
        gas_price,
        state
      ) do
    tx_hash =
      Transaction.hash(metatx)
      |> Base16.encode()

    cond do
      tx_nonce <= nonce ->
        Logger.info("RTX done: #{tx_hash}")
        process(rest, nonce, gas_price, state)

      tx_gas_price < gas_price ->
        Logger.warning(
          "RTX gas price lower than reference #{tx_gas_price / gas_price} #{tx_hash}"
        )

        resubmit(tx_hash, payload, state)
        [{metatx, payload} | process(rest, nonce, gas_price, state)]

      true ->
        resubmit(tx_hash, payload, state)
        [{metatx, payload} | process(rest, nonce, gas_price, state)]
    end
  end

  defp resubmit(tx_hash, payload, %TxRelay{chain: chain}) do
    ret = RemoteChain.RPC.send_raw_transaction(chain, payload)
    Logger.info("Resubmit RTX: #{tx_hash}: #{inspect(ret)}")
  end

  defp name(chain) do
    impl = RemoteChain.chainimpl(chain)
    {:global, {__MODULE__, impl}}
  end
end
