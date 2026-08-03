# Diode Server
# Copyright 2021-2025 Diode
# Licensed under the Diode License, Version 1.1
defmodule Model.KademliaSqlTest do
  use ExUnit.Case

  alias DiodeClient.{Object, Wallet}

  setup do
    Model.CredSql.set_wallet(Wallet.new())
    Model.KademliaSql.clear()
    Model.KademliaSql.init()
    :ok
  end

  test "sync_registry_nodes upserts and removes stale on-chain rows" do
    a = Wallet.address!(Wallet.new())
    b = Wallet.address!(Wallet.new())

    assert :ok = Model.KademliaSql.sync_registry_nodes([a, b])

    assert Enum.sort(registry_addresses()) == Enum.sort([a, b, Diode.address()])

    assert :ok = Model.KademliaSql.sync_registry_nodes([a])

    assert Enum.sort(registry_addresses()) == Enum.sort([a, Diode.address()])
    refute b in registry_addresses()
  end

  test "known_good follows object presence" do
    node = Wallet.new()
    address = Wallet.address!(node)
    ring_key = KademliaRing.key(node)

    assert :ok = Model.KademliaSql.sync_registry_nodes([address])
    refute Model.KademliaSql.get_node(address).known_good

    server = Diode.self()
    Model.KademliaSql.put_object(ring_key, Object.encode!(server))

    assert Model.KademliaSql.refresh_known_good(address)
    assert Model.KademliaSql.get_node(address).known_good
  end

  test "mark_failed sets first_failure when known_good" do
    node = Wallet.new()
    address = Wallet.address!(node)
    ring_key = KademliaRing.key(node)

    assert :ok = Model.KademliaSql.sync_registry_nodes([address])
    Model.KademliaSql.put_object(ring_key, Object.encode!(Diode.self()))
    Model.KademliaSql.mark_stable(node)

    now = System.os_time(:second)
    Model.KademliaSql.mark_failed(node, now + 60)

    meta = Model.KademliaSql.get_node(address)
    assert meta.failures == 1
    assert meta.first_failure != nil
    assert meta.next_retry != nil
  end

  test "objects_page orders by key and paginates after_key" do
    for i <- 1..5 do
      Model.KademliaSql.put_object(<<i::256>>, Object.encode!(Diode.self()))
    end

    page1 = Model.KademliaSql.objects_page(nil, 2)
    assert Enum.map(page1, &elem(&1, 0)) == [<<1::256>>, <<2::256>>]

    page2 = Model.KademliaSql.objects_page(<<2::256>>, 2)
    assert Enum.map(page2, &elem(&1, 0)) == [<<3::256>>, <<4::256>>]

    page3 = Model.KademliaSql.objects_page(<<4::256>>, 10)
    assert Enum.map(page3, &elem(&1, 0)) == [<<5::256>>]
  end

  test "objects_page excludes objects past stale silence deadline" do
    fresh = <<10::256>>
    stale = <<11::256>>
    value = Object.encode!(Diode.self())

    Model.KademliaSql.put_object(fresh, value)
    Model.KademliaSql.put_object(stale, value)

    Model.KademliaSql.query!(
      "UPDATE p2p_objects SET stored_at = ?1 WHERE key = ?2",
      [Model.KademliaSql.stale_silence_deadline() - 1, stale]
    )

    keys = Model.KademliaSql.objects_page(nil, 100) |> Enum.map(&elem(&1, 0))
    assert fresh in keys
    refute stale in keys
  end

  defp registry_addresses() do
    Model.KademliaSql.query!("SELECT address FROM p2p_nodes WHERE on_chain = 1")
    |> Enum.map(&hd/1)
  end
end
