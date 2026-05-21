# Diode Server
# Copyright 2021-2025 Diode
# Licensed under the Diode License, Version 1.1
defmodule KademliaLightCacheTest do
  use ExUnit.Case, async: true

  setup do
    Application.ensure_all_started(:diode_client)
    DiodeClient.ETSLru.new(KademliaLight, 8, fn _ -> true end)

    on_exit(fn ->
      try do
        DiodeClient.ETSLru.destroy(KademliaLight)
      rescue
        _ -> :ok
      end
    end)

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
