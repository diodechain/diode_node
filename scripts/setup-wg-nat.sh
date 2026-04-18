#!/bin/bash
# Diode Server
# Copyright 2021-2026 Diode
# Licensed under the Diode License, Version 1.1
#
# One-shot, idempotent NAT/forwarding setup for the WireGuard exit node.
#
# `WireGuardKernel` brings the `diode_wg` interface up, assigns
# `WIREGUARD_GATEWAY_CIDR` (default `10.0.0.1/24`), and enables IPv4 forwarding
# from inside the BEAM via netlink. On Linux, `WireGuardNat` also tries to run
# the same iptables rules automatically when the process can (e.g. root). If that
# fails, use this script — the `iptables` binary often cannot netfilter from an
# unprivileged BEAM even when beam.smp has caps.
#
# Run this script ONCE per host with sudo. It is safe to re-run.
#
#   sudo bin/setup-wg-nat.sh
#
# Env overrides (with defaults):
#   WG_SUBNET   default 10.0.0.0/24      (must match WIREGUARD_TUNNEL_SUBNET)
#   WG_IFACE    default diode_wg         (must match WIREGUARD_INTERFACE)
#   EGRESS_DEV  auto-detected default route iface (e.g. eth0/wlan0)
#
# Picks an iptables wrapper that matches the host netfilter path: if both legacy and nft are
# active, `iptables-nft` warns "iptables-legacy tables present" — then we use iptables-legacy
# (same as Docker on many Debian/Ubuntu hosts). Otherwise we use the distribution `iptables`
# entrypoint first (update-alternatives), then explicit legacy / nft wrappers.

set -euo pipefail

# Prints the chosen iptables command name (no path); empty if none found.
select_iptables() {
  if command -v iptables-nft >/dev/null 2>&1; then
    if iptables-nft -t filter -S 2>&1 | grep -Fq "iptables-legacy tables present"; then
      if command -v iptables-legacy >/dev/null 2>&1; then
        printf '%s' "iptables-legacy"
        return
      fi
    fi
  fi
  if command -v iptables >/dev/null 2>&1; then
    printf '%s' "iptables"
    return
  fi
  if command -v iptables-legacy >/dev/null 2>&1; then
    printf '%s' "iptables-legacy"
    return
  fi
  if command -v iptables-nft >/dev/null 2>&1; then
    printf '%s' "iptables-nft"
    return
  fi
  printf ''
}

WG_SUBNET="${WG_SUBNET:-10.0.0.0/24}"
WG_IFACE="${WG_IFACE:-diode_wg}"

if [ -z "${EGRESS_DEV:-}" ]; then
  EGRESS_DEV=$(ip route show default 0.0.0.0/0 | awk '/^default/ {print $5; exit}')
fi
if [ -z "$EGRESS_DEV" ]; then
  echo "ERROR: could not auto-detect default-route egress device; set EGRESS_DEV=..." >&2
  exit 2
fi

if [ "$(id -u)" != "0" ]; then
  echo "ERROR: must run as root (try: sudo $0)" >&2
  exit 1
fi

IPT="$(select_iptables)"
if [ -z "$IPT" ]; then
  echo "ERROR: no iptables binary found (tried iptables / iptables-legacy / iptables-nft)" >&2
  exit 2
fi

echo "[setup-wg-nat] using $IPT, subnet=$WG_SUBNET, wg=$WG_IFACE, egress=$EGRESS_DEV"

# net.ipv4.ip_forward — WireGuardKernel already does this from BEAM, but make
# sure it survives reboots even when the BEAM is not yet running.
sysctl -w net.ipv4.ip_forward=1 >/dev/null

mkdir -p /etc/sysctl.d
cat >/etc/sysctl.d/60-diode-wg.conf <<EOF
# Managed by diode_node_vpn/scripts/setup-wg-nat.sh
net.ipv4.ip_forward = 1
EOF

# Idempotent install: -C tests, -A appends only when absent.
ensure_rule() {
  local table="$1"; shift
  local chain="$1"; shift
  if ! "$IPT" -t "$table" -C "$chain" "$@" 2>/dev/null; then
    "$IPT" -t "$table" -A "$chain" "$@"
    echo "[setup-wg-nat] installed: -t $table -A $chain $*"
  else
    echo "[setup-wg-nat] already present: -t $table -A $chain $*"
  fi
}

# SNAT/MASQUERADE peer traffic out of the egress interface.
ensure_rule nat POSTROUTING -s "$WG_SUBNET" -o "$EGRESS_DEV" -j MASQUERADE

# Allow forwarding both directions for tunnel <-> WAN traffic.
ensure_rule filter FORWARD -i "$WG_IFACE" -o "$EGRESS_DEV" -j ACCEPT
ensure_rule filter FORWARD -i "$EGRESS_DEV" -o "$WG_IFACE" \
  -m state --state RELATED,ESTABLISHED -j ACCEPT

echo "[setup-wg-nat] done. Test with:"
echo "  ping -I $WG_IFACE -c1 1.1.1.1   # from another host on the tunnel"
echo "  $IPT -t nat -nvL POSTROUTING | grep MASQUERADE"
