# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1

defmodule TurnService do
  @moduledoc false
  use GenServer
  require Logger

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc false
  def operational? do
    case Process.whereis(__MODULE__) do
      nil -> false
      _pid -> GenServer.call(__MODULE__, :operational?)
    end
  end

  @impl true
  def init(_) do
    if Diode.Turn.turn_enabled?() do
      case start_turn_stack() do
        {:ok, pid} ->
          Logger.info("TURN server listening (configured)")
          {:ok, %{xturn_supervisor: pid}}

        {:error, reason} ->
          Logger.error("TURN failed to start: #{inspect(reason)}")
          {:ok, %{xturn_supervisor: nil}}
      end
    else
      Logger.info("TURN disabled (TURN_ENABLED unset)")
      {:ok, %{xturn_supervisor: nil}}
    end
  end

  @impl true
  def handle_call(:operational?, _from, state) do
    {:reply, state.xturn_supervisor != nil, state}
  end

  defp start_turn_stack do
    Diode.Turn.apply_xturn_runtime_config!()
    Xirsys.XTurn.start_servers()
  end
end
