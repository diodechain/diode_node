# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule ObjectTest do
  use ExUnit.Case, async: true
  import TestHelper
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
end
