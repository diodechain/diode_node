# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Model.KademliaSql do
  alias RemoteChain.RPCCache
  alias Model.Sql
  alias DiodeClient.{Object, Wallet}
  alias KademliaLight.Node
  import DiodeClient.Object.TicketV2, only: :macros
  import Wallet
  require Logger

  @redistribute_after_seconds 20 * 60

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

    query!("""
        CREATE TABLE IF NOT EXISTS p2p_nodes (
          address BLOB PRIMARY KEY,
          ring_key BLOB NOT NULL,
          on_chain INTEGER NOT NULL DEFAULT 0,
          known_good INTEGER NOT NULL DEFAULT 0,
          failures INTEGER NOT NULL DEFAULT 0,
          last_connected INTEGER,
          last_error INTEGER,
          next_retry INTEGER,
          first_failure INTEGER,
          synced_at INTEGER NOT NULL DEFAULT 0
        )
    """)

    query!("CREATE INDEX IF NOT EXISTS idx_p2p_nodes_ring_key ON p2p_nodes(ring_key)")
    query!("CREATE INDEX IF NOT EXISTS idx_p2p_nodes_on_chain ON p2p_nodes(on_chain)")
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
    query!("DELETE FROM p2p_nodes")
  end

  def clear_nodes() do
    query!("DELETE FROM p2p_nodes")
  end

  def sync_registry_nodes(addresses \\ nil) do
    addresses =
      case addresses do
        nil ->
          case Contract.NodeRegistry.nodes_above(Shell.ether(1)) do
            {:error, reason} ->
              Logger.error("Node registry sync failed: #{inspect(reason)}")
              :error

            list when is_list(list) ->
              list
          end

        list when is_list(list) ->
          list
      end

    if addresses == :error do
      :error
    else
      now = now_seconds()
      registry_set = MapSet.new(addresses)

      removed =
        query!("SELECT address FROM p2p_nodes WHERE on_chain = 1")
        |> Enum.map(&hd/1)
        |> Enum.filter(fn addr -> not MapSet.member?(registry_set, addr) end)

      for addr <- removed do
        KademliaLight.redistribute_removed_node(addr)
      end

      query!("BEGIN IMMEDIATE")

      try do
        for addr <- removed do
          query!("DELETE FROM p2p_nodes WHERE address = ?1", [addr])
        end

        for address <- addresses do
          ring_key = KademliaRing.key(address)

          query!(
            """
            INSERT INTO p2p_nodes (address, ring_key, on_chain, synced_at)
            VALUES (?1, ?2, 1, ?3)
            ON CONFLICT(address) DO UPDATE SET
              on_chain = 1,
              ring_key = excluded.ring_key,
              synced_at = excluded.synced_at
            """,
            [address, ring_key, now]
          )
        end

        ensure_self_node(now)
        refresh_known_good_all()
        query!("COMMIT")
      rescue
        exception ->
          _ = query!("ROLLBACK")
          reraise(exception, __STACKTRACE__)
      end

      GenServer.cast(KademliaLight, :reload_ring)
      :ok
    end
  end

  def ensure_self_node_for_init() do
    ensure_self_node(now_seconds())
  end

  defp ensure_self_node(now) do
    address = Diode.address()
    ring_key = KademliaRing.key(Diode.wallet())

    query!(
      """
      INSERT INTO p2p_nodes (address, ring_key, on_chain, known_good, synced_at, last_connected)
      VALUES (?1, ?2, 1, 1, ?3, ?3)
      ON CONFLICT(address) DO UPDATE SET
        on_chain = 1,
        ring_key = excluded.ring_key,
        known_good = 1
      """,
      [address, ring_key, now]
    )
  end

  def refresh_known_good_all() do
    query!(
      """
      UPDATE p2p_nodes SET known_good = CASE
        WHEN EXISTS (
          SELECT 1 FROM p2p_objects
          WHERE p2p_objects.key = p2p_nodes.ring_key
            AND p2p_objects.stored_at > ?1
        ) THEN 1 ELSE 0 END
      WHERE on_chain = 1
      """,
      [stale_silence_deadline()]
    )
  end

  def refresh_known_good(address) do
    ring_key = KademliaRing.key(address)
    kg = if object(ring_key) != nil, do: 1, else: 0

    query!("UPDATE p2p_nodes SET known_good = ?1 WHERE address = ?2", [kg, address])
    kg == 1
  end

  def list_on_chain_nodes() do
    query!(
      "SELECT address, ring_key, known_good, failures, last_connected, last_error, next_retry, first_failure FROM p2p_nodes WHERE on_chain = 1"
    )
    |> Enum.map(&row_to_node/1)
  end

  def get_node(address) do
    case query!(
           "SELECT address, ring_key, known_good, failures, last_connected, last_error, next_retry, first_failure FROM p2p_nodes WHERE address = ?1",
           [address]
         ) do
      [row] -> row_to_meta(row)
      [] -> nil
    end
  end

  defp row_to_node([
         address,
         ring_key,
         known_good,
         failures,
         last_connected,
         last_error,
         next_retry,
         first_failure
       ]) do
    node = Node.new(Wallet.from_address(address))

    {node,
     %{
       known_good: known_good == 1,
       failures: failures || 0,
       last_connected: last_connected,
       last_error: last_error,
       next_retry: next_retry,
       first_failure: first_failure,
       ring_key: ring_key
     }}
  end

  defp row_to_meta(row) do
    {_node, meta} = row_to_node(row)
    meta
  end

  def upsert_node_from_connection(wallet() = node_id, attrs \\ %{}) do
    address = Wallet.address!(node_id)
    ring_key = KademliaRing.key(node_id)
    now = now_seconds()

    known_good = if Map.get(attrs, :known_good, false), do: 1, else: 0
    last_connected = Map.get(attrs, :last_connected, now)
    on_chain = if Map.get(attrs, :on_chain, false), do: 1, else: 0

    query!(
      """
      INSERT INTO p2p_nodes (address, ring_key, on_chain, known_good, last_connected, synced_at, failures, first_failure, last_error, next_retry)
      VALUES (?1, ?2, ?3, ?4, ?5, ?5, 0, NULL, NULL, NULL)
      ON CONFLICT(address) DO UPDATE SET
        known_good = MAX(p2p_nodes.known_good, excluded.known_good),
        last_connected = COALESCE(excluded.last_connected, p2p_nodes.last_connected),
        failures = 0,
        first_failure = NULL,
        last_error = NULL,
        next_retry = NULL
      """,
      [address, ring_key, on_chain, known_good, last_connected]
    )
  end

  def mark_stable(wallet() = node_id) do
    address = Wallet.address!(node_id)
    refresh_known_good(address)

    query!(
      """
      UPDATE p2p_nodes SET
        known_good = 1,
        failures = 0,
        first_failure = NULL,
        last_error = NULL,
        next_retry = NULL,
        last_connected = ?1
      WHERE address = ?2
      """,
      [now_seconds(), address]
    )
  end

  def mark_failed(wallet() = node_id, next_retry) do
    address = Wallet.address!(node_id)
    now = now_seconds()

    if get_node(address) == nil do
      upsert_node_from_connection(node_id, %{})
    end

    meta = get_node(address) || %{known_good: false, failures: 0, first_failure: nil}

    first_failure =
      if meta.known_good and (meta.first_failure == nil or meta.failures == 0) do
        now
      else
        meta.first_failure || now
      end

    failures = (meta.failures || 0) + 1

    query!(
      """
      UPDATE p2p_nodes SET
        failures = ?1,
        last_error = ?2,
        next_retry = ?3,
        first_failure = ?4
      WHERE address = ?5
      """,
      [failures, now, next_retry, first_failure, address]
    )
  end

  def nodes_needing_redistribution(now \\ now_seconds()) do
    cutoff = now - @redistribute_after_seconds

    query!(
      """
      SELECT address, ring_key FROM p2p_nodes
      WHERE known_good = 1
        AND first_failure IS NOT NULL
        AND first_failure <= ?1
      """,
      [cutoff]
    )
    |> Enum.map(fn [address, ring_key] -> {address, ring_key} end)
  end

  def delete_nodes_by_ring_keys(keys) when is_list(keys) do
    for key <- keys do
      query!("DELETE FROM p2p_nodes WHERE ring_key = ?1 AND address != ?2", [
        key,
        Diode.address()
      ])
    end
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
      # querying stale objects to ensure we won't re-store a stale object
      case stale_object_ext(hkey) do
        nil ->
          put_object(hkey, Object.encode!(object))

        {existing, stale?} ->
          existing_object = Object.decode!(existing)

          case {Object.modname(existing_object), Object.modname(object)} do
            {Object.TicketV1, Object.TicketV2} ->
              put_object(hkey, Object.encode!(object))

            {Object.TicketV2, Object.TicketV1} ->
              existing_object

            _ ->
              if Object.block_number(existing_object) < Object.block_number(object) do
                put_object(hkey, Object.encode!(object))
              else
                if stale? do
                  nil
                else
                  existing_object
                end
              end
          end
      end
    end
  end

  def put_object(key, object) do
    query!(
      "REPLACE INTO p2p_objects (key, object, stored_at) VALUES(?1, ?2, ?3)",
      [key, BertInt.encode!(object), now_seconds()]
    )

    object
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

  defp stale_object_ext(key) do
    case Sql.query!(__MODULE__, "SELECT object, stored_at FROM p2p_objects WHERE key = ?1", [key]) do
      [[object_blob, stored_at]] ->
        {BertInt.decode!(object_blob), stored_at < stale_silence_deadline()}

      [] ->
        nil
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
    self = KademliaRing.key(Diode.wallet())

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
