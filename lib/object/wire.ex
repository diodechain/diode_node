# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule DiodeClient.Object.Wire do
  @moduledoc false
  alias DiodeClient.{BertExt, Object, Object.Ticket}

  @ticket_tags [:ticketv1, :ticketv2]

  @spec encode!(tuple()) :: binary()
  def encode!(object) do
    encode_list!(object)
    |> BertExt.encode!()
  end

  @spec encode_list!(tuple()) :: list()
  def encode_list!(object) when is_tuple(object) do
    case elem(object, 0) do
      type when type in @ticket_tags ->
        Ticket.wire_encode_list!(object)

      _ ->
        Object.encode_list!(object)
    end
  end
end
