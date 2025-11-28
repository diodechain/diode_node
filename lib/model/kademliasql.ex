# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Model.KademliaSql do
  alias RemoteChain.RPCCache
  alias Model.Sql
  alias DiodeClient.Object
  alias KBuckets
  import DiodeClient.Object.TicketV2, only: :macros
  require Logger

  @day_seconds 86_400
  # Don't report after two days
  @stale_silence_seconds @day_seconds * 2
  def stale_silence_deadline(), do: now_seconds() - @stale_silence_seconds
  # Prune after four days
  @stale_prune_seconds @day_seconds * 4
  def stale_prune_deadline(), do: now_seconds() - @stale_prune_seconds

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

  def archive() do
    query!("UPDATE p2p_objects SET stored_at = ?1", [stale_silence_deadline()])
  end

  def stale_size() do
    case query!("SELECT COUNT(*) FROM p2p_objects") do
      [[count]] -> count
      [] -> 0
    end
  end

  def size() do
    case query!("SELECT COUNT(*) FROM p2p_objects WHERE stored_at > ?1", [
           stale_silence_deadline()
         ]) do
      [[count]] -> count
      [] -> 0
    end
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
      # querying stale objects too ensure we won't re-store a stale object
      case stale_object(hkey) do
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
    case Sql.query!(
           __MODULE__,
           "SELECT object FROM p2p_objects WHERE key = ?1 AND stored_at > ?2",
           [key, stale_silence_deadline()]
         ) do
      [[object_blob]] -> BertInt.decode!(object_blob)
      [] -> nil
    end
  end

  def stale_object(key) do
    case Sql.query!(__MODULE__, "SELECT object FROM p2p_objects WHERE key = ?1", [key]) do
      [[object_blob]] -> BertInt.decode!(object_blob)
      [] -> nil
    end
  end

  def scan() do
    query!("SELECT key, object FROM p2p_objects WHERE stored_at > ?1", [
      stale_silence_deadline()
    ])
    |> Enum.reduce([], fn [key, object_blob], acc ->
      [{key, Object.decode!(BertInt.decode!(object_blob))} | acc]
    end)
    |> Enum.reverse()
  end

  def objects(range_start, range_end) do
    bstart = <<range_start::integer-size(256)>>
    bend = <<range_end::integer-size(256)>>

    if range_start < range_end do
      query!(
        "SELECT key, object FROM p2p_objects WHERE (key >= ?1 AND key <= ?2) AND stored_at > ?3",
        [bstart, bend, stale_silence_deadline()]
      )
    else
      query!(
        "SELECT key, object FROM p2p_objects WHERE (key >= ?1 OR key <= ?2) AND stored_at > ?3",
        [bstart, bend, stale_silence_deadline()]
      )
    end
    |> Enum.reduce([], fn [key, object_blob], acc ->
      [{key, BertInt.decode!(object_blob)} | acc]
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

  def prune_stale_objects() do
    cutoff = stale_prune_deadline()
    removed = prune_stale_chunk(cutoff, 0)

    if removed > 0 do
      Logger.info("Removed #{removed} stale ticket objects")
    end

    removed
  end

  defp prune_stale_chunk(cutoff, acc) do
    self = KBuckets.key(Diode.wallet())

    stale_keys =
      query!("SELECT key FROM p2p_objects WHERE stored_at < ?1 AND key != ?2 LIMIT 100", [
        cutoff,
        self
      ])
      |> Enum.map(&hd/1)

    case stale_keys do
      [] ->
        acc

      keys ->
        KademliaLight.drop_nodes(keys)

        for key <- keys do
          query!("DELETE FROM p2p_objects WHERE key = ?1", [key])
        end

        prune_stale_chunk(cutoff, acc + length(keys))
    end
  end

  defp now_seconds(), do: System.os_time(:second)

  def clear_invalid_objects() do
    await(Chains.Diode)
    await(Chains.Moonbeam)
    epoch = TicketStore.epoch() - 1

    count =
      scan()
      |> Enum.filter(fn {_key, obj} ->
        case obj do
          ticketv2(epoch: tepoch) -> tepoch >= epoch
          _ -> false
        end
      end)
      |> Enum.map(fn {key, obj} ->
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
