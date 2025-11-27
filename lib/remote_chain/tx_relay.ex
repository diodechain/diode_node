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
    defstruct [:metatx, :payload, :sender, :timestamp]
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
    GenServerDbg.call(name(chain), {:pending_sender_tx?, sender})
  end

  def keep_alive(chain, metatx, payload, sender) do
    GenServer.cast(name(chain), %Tx{
      metatx: metatx,
      payload: payload,
      sender: sender,
      timestamp: System.os_time(:second)
    })
  end

  @impl true
  def handle_call({:pending_sender_tx?, sender}, _from, %TxRelay{txlist: txlist} = state) do
    {:reply, Enum.any?(txlist, fn tx -> tx.sender == sender end), state}
  end

  @impl true
  def handle_cast(tx = %Tx{metatx: metatx}, %TxRelay{txlist: txlist} = state) do
    nonce = Transaction.nonce(metatx)

    txlist =
      Enum.reject(txlist, fn tx ->
        tx_nonce = Transaction.nonce(tx.metatx)
        tx_hash = Transaction.hash(tx.metatx) |> Base16.encode()
        tx_chain_id = Transaction.chain_id(tx.metatx)

        if tx_nonce >= nonce do
          Logger.info(
            "RTX removing tx #{tx_chain_id}/#{tx_nonce} => #{tx_hash} because it's >= #{nonce}"
          )

          true
        else
          false
        end
      end)

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
          tx = %Tx{metatx: metatx = %Transaction{nonce: tx_nonce, gasPrice: tx_gas_price}}
          | rest
        ],
        nonce,
        gas_price,
        state
      ) do
    cond do
      tx_nonce < nonce ->
        tx_hash = Transaction.hash(metatx) |> Base16.encode()
        chain_id = Transaction.chain_id(metatx)
        nonce = Transaction.nonce(metatx)
        Logger.info("RTX done: #{chain_id}/#{nonce} => #{tx_hash}")
        process(rest, nonce, gas_price, state)

      tx.timestamp < System.os_time(:second) - 300 ->
        tx_hash = Transaction.hash(metatx) |> Base16.encode()
        chain_id = Transaction.chain_id(metatx)
        nonce = Transaction.nonce(metatx)
        Logger.warning("RTX timeout: #{chain_id}/#{nonce} => #{tx_hash}")
        process(rest, nonce, gas_price, state)

      tx_gas_price < gas_price ->
        tx_hash = Transaction.hash(metatx) |> Base16.encode()

        "RTX gas price lower than reference #{tx_gas_price}, #{gas_price} #{tx_hash}"
        |> Logger.warning()

        resubmit(tx, state)
        [tx | process(rest, nonce, gas_price, state)]

      true ->
        resubmit(tx, state)
        [tx | process(rest, nonce, gas_price, state)]
    end
  end

  defp resubmit(%Tx{metatx: metatx, payload: payload}, %TxRelay{chain: chain}) do
    tx_hash = Transaction.hash(metatx) |> Base16.encode()
    ret = RemoteChain.RPC.send_raw_transaction(chain, payload)
    chain_id = Transaction.chain_id(metatx)
    nonce = Transaction.nonce(metatx)
    Logger.info("Resubmit RTX: #{chain_id}/#{nonce} => #{tx_hash}: #{inspect(ret)}")
  end

  defp name(chain) do
    impl = RemoteChain.chainimpl(chain)
    {:global, {__MODULE__, impl}}
  end
end
