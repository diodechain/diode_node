# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Model.KademliaSql do
  alias RemoteChain.RPCCache
  alias Model.Sql
  alias DiodeClient.{Object}
  import DiodeClient.Object.TicketV2
  require Logger

  def query!(sql, params \\ []) do
    Sql.query!(__MODULE__, sql, params)
  end

  def init() do
    query!("""
        CREATE TABLE IF NOT EXISTS p2p_objects (
          key BLOB PRIMARY KEY,
          object BLOB
        )
    """)
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
    query!("REPLACE INTO p2p_objects (key, object) VALUES(?1, ?2)", [key, object])
  end

  def delete_object(key) do
    query!("DELETE FROM p2p_objects WHERE key = ?1", [key])
  end

  def object(key) do
    Sql.fetch!(__MODULE__, "SELECT object FROM p2p_objects WHERE key = ?1", key)
  end

  def scan() do
    query!("SELECT key, object FROM p2p_objects")
    |> Enum.map(fn [key, obj] ->
      obj = BertInt.decode!(obj) |> Object.decode!()
      {key, obj}
    end)
  end

  @spec objects(integer, integer) :: any
  def objects(range_start, range_end) do
    bstart = <<range_start::integer-size(256)>>
    bend = <<range_end::integer-size(256)>>

    if range_start < range_end do
      query!(
        "SELECT key, object FROM p2p_objects WHERE key >= ?1 AND key <= ?2",
        [bstart, bend]
      )
    else
      query!(
        "SELECT key, object FROM p2p_objects WHERE key >= ?1 OR key <= ?2",
        [bstart, bend]
      )
    end
    |> Enum.map(fn [key, obj] -> {key, BertInt.decode!(obj)} end)
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
