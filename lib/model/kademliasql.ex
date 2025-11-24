# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Model.KademliaSql do
  alias RemoteChain.RPCCache
  alias Model.Sql
  alias DiodeClient.{Object}
  alias DiodeClient.Object.Ticket, as: Ticket
  import DiodeClient.Object.TicketV1, only: :macros
  import DiodeClient.Object.TicketV2, only: :macros
  require Logger

  @ticket_epoch_grace 1
  @ticket_ttl_seconds 24 * 60 * 60

  def query!(sql, params \\ []) do
    Sql.query!(__MODULE__, sql, params)
  end

  def init() do
    query!("""
        CREATE TABLE IF NOT EXISTS p2p_objects (
          key BLOB PRIMARY KEY,
          object BLOB,
          stored_at INTEGER NOT NULL
        )
    """)

    ensure_stored_at_column()
  end

  defp ensure_stored_at_column() do
    unless has_column?("stored_at") do
      query!("ALTER TABLE p2p_objects ADD COLUMN stored_at INTEGER NOT NULL DEFAULT 0")
      query!("UPDATE p2p_objects SET stored_at = strftime('%s','now') WHERE stored_at = 0")
    end
  end

  defp has_column?(column) do
    query!("PRAGMA table_info(p2p_objects)")
    |> Enum.any?(fn [_, name, _type, _notnull, _default, _pk] -> name == column end)
  end

  def clear() do
    query!("DELETE FROM p2p_objects")
  end

  def append!(_key, _value) do
    throw(:not_implemented)
  end

  def maybe_update_object(key, encoded_object) when is_binary(encoded_object) do
    object = Object.decode!(encoded_object)
    maybe_update_object(key, object)
  end

  def maybe_update_object(key, object) when is_tuple(object) do
    hkey = KademliaLight.hash(Object.key(object))
    # Checking that we got a valid object
    if key == nil or key == hkey do
      case object(hkey) do
        nil ->
          put_object(hkey, Object.encode!(object))

        existing ->
          existing_object = Object.decode!(existing)

          case {Object.modname(existing_object), Object.modname(object)} do
            {Object.TicketV1, Object.TicketV2} ->
              put_object(hkey, Object.encode!(object))

            {Object.TicketV2, Object.TicketV1} ->
              nil

            _ ->
              if Object.block_number(existing_object) < Object.block_number(object) do
                put_object(hkey, Object.encode!(object))
              end
          end
      end
    end

    hkey
  end

  def put_object(key, object) do
    object = BertInt.encode!(object)

    query!(
      "REPLACE INTO p2p_objects (key, object, stored_at) VALUES(?1, ?2, ?3)",
      [key, object, now_seconds()]
    )
  end

  def delete_object(key) do
    query!("DELETE FROM p2p_objects WHERE key = ?1", [key])
  end

  def object(key) do
    Sql.query!(__MODULE__, "SELECT object, stored_at FROM p2p_objects WHERE key = ?1", [key])
    |> case do
      [[object_blob, stored_at]] ->
        case decode_binary(key, object_blob, stored_at) do
          {_, binary, _} -> binary
          nil -> nil
        end

      [] ->
        nil
    end
  end

  def scan() do
    query!("SELECT key, object, stored_at FROM p2p_objects")
    |> Enum.reduce([], fn row, acc ->
      case decode_term_row(row) do
        nil -> acc
        tuple -> [tuple | acc]
      end
    end)
    |> Enum.reverse()
  end

  @spec objects(integer, integer) :: any
  def objects(range_start, range_end) do
    bstart = <<range_start::integer-size(256)>>
    bend = <<range_end::integer-size(256)>>

    if range_start < range_end do
      query!(
        "SELECT key, object, stored_at FROM p2p_objects WHERE key >= ?1 AND key <= ?2",
        [bstart, bend]
      )
    else
      query!(
        "SELECT key, object, stored_at FROM p2p_objects WHERE key >= ?1 OR key <= ?2",
        [bstart, bend]
      )
    end
    |> Enum.reduce([], fn row, acc ->
      case decode_binary_row(row) do
        nil -> acc
        {key, binary, _stored_at} -> [{key, binary} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp await(chain) do
    case RPCCache.whereis(chain) do
      nil ->
        Logger.warning("Waiting for RPC cache to start for #{chain}")
        Process.sleep(5000)
        await(chain)

      _ ->
        :ok
    end
  end

  defp decode_binary_row([key, object_blob, stored_at]) do
    decode_binary(key, object_blob, stored_at)
  end

  defp decode_term_row(row) do
    with {key, binary, stored_at} <- decode_binary_row(row) do
      {key, Object.decode!(binary), stored_at}
    end
  end

  defp decode_binary(key, object_blob, stored_at) do
    binary = BertInt.decode!(object_blob)

    if stale_object?(binary, stored_at) do
      delete_object(key)
      nil
    else
      {key, binary, stored_at}
    end
  end

  defp stale_object?(binary, stored_at, now \\ now_seconds()) do
    case maybe_decode_ticket(binary) do
      {:ticket, ticket} -> stale_ticket?(ticket, stored_at, now)
      _ -> false
    end
  end

  defp maybe_decode_ticket(binary) do
    case safe_decode_object(binary) do
      {:ok, ticketv1() = ticket} -> {:ticket, ticket}
      {:ok, ticketv2() = ticket} -> {:ticket, ticket}
      _ -> :not_ticket
    end
  end

  defp safe_decode_object(binary) do
    {:ok, Object.decode!(binary)}
  rescue
    _ -> :error
  end

  defp stale_ticket?(ticket, stored_at, now) do
    time_expired?(stored_at, now) or epoch_expired?(ticket)
  end

  defp time_expired?(stored_at, now)
       when is_integer(stored_at) and stored_at > 0 do
    now - stored_at > @ticket_ttl_seconds
  end

  defp time_expired?(_stored_at, _now), do: false

  defp epoch_expired?(ticket) do
    chain_id = safe_chain_id(ticket)
    epoch = safe_ticket_epoch(ticket)

    cond do
      chain_id == nil or epoch == nil ->
        false

      true ->
        with {:ok, current_epoch} <- safe_chain_epoch(chain_id) do
          epoch + @ticket_epoch_grace < current_epoch
        else
          _ -> false
        end
    end
  end

  defp safe_chain_id(ticket) do
    Ticket.chain_id(ticket)
  rescue
    _ -> nil
  end

  defp safe_ticket_epoch(ticket) do
    Ticket.epoch(ticket)
  rescue
    _ -> nil
  end

  defp safe_chain_epoch(chain_id) do
    {:ok, RemoteChain.epoch(chain_id)}
  rescue
    _ -> :error
  end

  def prune_stale_objects() do
    now = now_seconds()

    removed =
      query!("SELECT key, object, stored_at FROM p2p_objects")
      |> Enum.reduce(0, fn [key, object_blob, stored_at], acc ->
        binary = BertInt.decode!(object_blob)

        if stale_object?(binary, stored_at, now) do
          delete_object(key)
          acc + 1
        else
          acc
        end
      end)

    if removed > 0 do
      Logger.info("Removed #{removed} stale ticket objects")
    end

    removed
  end

  defp now_seconds(), do: System.os_time(:second)

  def clear_invalid_objects() do
    await(Chains.Diode)
    await(Chains.Moonbeam)
    epoch = TicketStore.epoch() - 1

    count =
      scan()
      |> Enum.filter(fn {_key, obj, _stored_at} ->
        case obj do
          ticketv2(epoch: tepoch) -> tepoch >= epoch
          _ -> false
        end
      end)
      |> Enum.map(fn {key, obj, _stored_at} ->
        # After a chain fork some signatures might have become invalid
        hash = obj |> Object.key() |> KademliaLight.hash()

        if key != hash do
          Logger.warning(
            "Clearing invalid object #{Base.encode16(key)} != #{Base.encode16(hash)}"
          )

          query!("DELETE FROM p2p_objects WHERE key = ?1", [key])
        end
      end)
      |> Enum.count()

    Logger.info("Consolidated #{count} objects")
  end
end
