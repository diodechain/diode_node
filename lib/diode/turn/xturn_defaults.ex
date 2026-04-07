# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1

defmodule Diode.Turn.XturnDefaults do
  @moduledoc false

  # Mirrors xturn 0.1.2 default pipes (config/config.exs in upstream); only Authenticates is swapped.
  @base_pipes %{
    allocate: [
      Xirsys.XTurn.Actions.HasRequestedTransport,
      Xirsys.XTurn.Actions.Authenticates,
      Xirsys.XTurn.Actions.NotAllocationExists,
      Xirsys.XTurn.Actions.Allocate
    ],
    refresh: [
      Xirsys.XTurn.Actions.Authenticates,
      Xirsys.XTurn.Actions.Refresh
    ],
    channelbind: [
      Xirsys.XTurn.Actions.Authenticates,
      Xirsys.XTurn.Actions.ChannelBind
    ],
    createperm: [
      Xirsys.XTurn.Actions.Authenticates,
      Xirsys.XTurn.Actions.CreatePerm
    ],
    send: [Xirsys.XTurn.Actions.SendIndication],
    channeldata: [Xirsys.XTurn.Actions.ChannelData]
  }

  @doc """
  Returns the `:pipes` map with `Xirsys.XTurn.Actions.Authenticates` replaced by `Diode.Turn.Authenticates`.
  """
  def pipes_with_diode_auth do
    for {k, list} <- @base_pipes, into: %{} do
      {k, Enum.map(list, &replace_auth/1)}
    end
  end

  defp replace_auth(Xirsys.XTurn.Actions.Authenticates), do: Diode.Turn.Authenticates
  defp replace_auth(m), do: m
end
