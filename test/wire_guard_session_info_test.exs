# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1

defmodule WireGuardSessionInfoTest do
  use ExUnit.Case

  describe "session_info_map/4" do
    test "returns WireGuardSessionInfo with string keys and integer listen_port" do
      m =
        WireGuardService.session_info_map(
          "bW9jazEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE=",
          "198.51.100.77",
          51_820,
          "10.0.0.2/32"
        )

      assert m["server_public_key"] ==
               "bW9jazEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE="

      assert m["endpoint_host"] == "198.51.100.77"
      assert m["listen_port"] == 51_820
      assert m["client_address"] == "10.0.0.2/32"
      assert map_size(m) == 4
    end
  end
end
