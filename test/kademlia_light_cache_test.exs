# Diode Server
# Copyright 2021-2025 Diode
# Licensed under the Diode License, Version 1.1
defmodule KademliaLightCacheTest do
  use ExUnit.Case, async: false

  setup do
    Application.ensure_all_started(:diode_client)
    :ok
  end

  test "get_cached passes data key to callback not cache tag" do
    hashed = <<0::256>>

    assert KademliaLight.get_cached_test(
             fn
               {:find_value, _} -> flunk("cache tag tuple was passed to callback")
               ^hashed -> :ok
               other -> flunk("unexpected callback arg: #{inspect(other)}")
             end,
             {:find_value, hashed},
             hashed
           ) == :ok
  end
end
