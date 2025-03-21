# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Channels do
  # Automatically defines child_spec/1
  use Supervisor
  alias DiodeClient.Object

  def start_link() do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_args) do
    Supervisor.init([], strategy: :one_for_one)
  end

  def ensure(ch) do
    Supervisor.start_child(__MODULE__, %{
      id: Object.Channel.key(ch),
      start: {Network.Channel, :start_link, [ch]}
    })
    |> case do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end
end
