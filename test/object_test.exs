# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule ObjectTest do
  use ExUnit.Case, async: true
  import TestHelper
  import DiodeClient.Object.TicketV2, only: [ticketv2: 1]
  alias Object.Server

  # Testing forward compatibility of server tickets

  test "forward/backward compatibility" do
    classic =
      {:server, "host", 1, 2, "a", "signature"}
      |> Object.Server.sign(Wallet.privkey!(Diode.wallet()))

    assert Server.host(classic) == "host"
    assert Server.edge_port(classic) == 1
    assert Server.peer_port(classic) == 2
    assert Server.key(classic) == Wallet.address!(Diode.wallet())

    extended =
      {:server, "host", 1, 2, "a", "b", "c", "signature"}
      |> Object.Server.sign(Wallet.privkey!(Diode.wallet()))

    assert Server.host(extended) == "host"
    assert Server.edge_port(extended) == 1
    assert Server.peer_port(extended) == 2
    assert Server.key(extended) == Wallet.address!(Diode.wallet())
  end

  test "encode/decode compat" do
    objs =
      for idx <- 1..100 do
        Object.Data.new(peaknumber(), "name_#{idx}", "value", Wallet.privkey!(Wallet.new()))
      end

    for object <- objs do
      key = Object.key(object)

      encoded = Object.encode!(object)
      decoded = Object.decode!(encoded)

      assert decoded == object
      assert Object.key(decoded) == key

      Model.KademliaSql.put_object(KademliaLight.hash(key), encoded)

      loaded =
        Model.KademliaSql.object(KademliaLight.hash(key))
        |> Object.decode!()

      assert Object.key(loaded) == key
    end

    <<max::integer-size(256)>> = String.duplicate(<<255>>, 32)

    map =
      Model.KademliaSql.objects(0, max)
      |> Map.new()

    for object <- objs do
      key = KademliaLight.hash(Object.key(object))
      assert Object.decode!(Map.get(map, key)) == object
    end
  end

  test "stale tickets expire based on ttl" do
    key = <<1::256>>
    persist_ticket(key)

    old = System.os_time(:second) - 2 * 24 * 60 * 60
    Model.KademliaSql.query!("UPDATE p2p_objects SET stored_at = ?1 WHERE key = ?2", [old, key])

    assert Model.KademliaSql.object(key) == nil
  end

  test "ticket gc removes stale rows" do
    key = <<2::256>>
    persist_ticket(key)

    old = System.os_time(:second) - 2 * 24 * 60 * 60
    Model.KademliaSql.query!("UPDATE p2p_objects SET stored_at = ?1 WHERE key = ?2", [old, key])

    assert Model.KademliaSql.prune_stale_objects() == 1
    assert Model.KademliaSql.object(key) == nil
  end

  defp persist_ticket(key, opts \\ []) do
    ticket =
      ticketv2(
        chain_id: chain().chain_id(),
        server_id: Wallet.address!(Diode.wallet()),
        total_connections: 1,
        total_bytes: Keyword.get(opts, :total_bytes, 1),
        local_address: "foo",
        epoch: Keyword.get(opts, :epoch, epoch()),
        fleet_contract: developer_fleet_address(),
        device_signature: <<0::520>>,
        server_signature: <<0::520>>
      )
      |> Object.encode!()

    Model.KademliaSql.put_object(key, ticket)
    key
  end
end
