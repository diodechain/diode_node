# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1

defmodule Diode.Turn.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(_opts \\ []) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    Supervisor.init(
      [
        Diode.Turn.CredentialStore,
        Diode.Turn.AccountingHook,
        TurnService
      ],
      strategy: :one_for_one
    )
  end
end
