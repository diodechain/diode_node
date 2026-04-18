# Diode Server
# Copyright 2021-2026 Diode
# Licensed under the Diode License, Version 1.1
defmodule WireGuardNatTest do
  use ExUnit.Case, async: true

  describe "default_egress_from_ip_route_output/1" do
    test "parses typical ip route default line" do
      out = "default via 192.168.1.1 dev wlp2s0 proto dhcp metric 600 \n"
      assert {:ok, "wlp2s0"} == WireGuardNat.default_egress_from_ip_route_output(out)
    end

    test "uses first line when multiple defaults" do
      out = """
      default via 10.0.2.2 dev eth0 metric 100
      default via 192.168.0.1 dev wlan0 metric 200
      """

      assert {:ok, "eth0"} == WireGuardNat.default_egress_from_ip_route_output(out)
    end

    test "returns error when no dev" do
      assert {:error, {:no_default_route, _}} =
               WireGuardNat.default_egress_from_ip_route_output("something weird")
    end
  end

  describe "iptables_binary_candidates/1" do
    test "legacy dual-stack hint forces legacy-first order" do
      assert WireGuardNat.iptables_binary_candidates(true) ==
               ~w(iptables-legacy iptables iptables-nft)
    end

    test "no legacy hint uses distribution default first" do
      assert WireGuardNat.iptables_binary_candidates(false) ==
               ~w(iptables iptables-legacy iptables-nft)
    end

    test ":auto returns a non-empty ordered list" do
      list = WireGuardNat.iptables_binary_candidates(:auto)

      assert list in [
               ~w(iptables-legacy iptables iptables-nft),
               ~w(iptables iptables-legacy iptables-nft)
             ]

      assert Enum.all?(list, &is_binary/1)
    end
  end
end
