![diode logo](https://diode.io/images/logo-trans.svg)
> ### Secure. Super Light. Web3. 

# Diode Network Relay Node

Relay nodes are at the heart of Diodes decentralized infrastructure network. Each node helps devices to communicate securely and efficiently through the Diode network. More nodes in more regions mean more available bandwidth for a growing network.

When deploying a node it should be setup on publicly reachable interfaces with a public IP. If the Node is not reachable from other nodes it might eventually get blocked and not receive any traffic. Nodes are gaining reputation over time when they stay up and available.

# Getting Started

To get started with the diode node install the latest snap release:

[![Get it from the Snap Store](https://snapcraft.io/en/dark/install.svg)](https://snapcraft.io/diode-node)

```bash
sudo snap install diode-node
```

## Snap Configuration

After installation all configuration values are available via the snap config system:

```bash
sudo snap get diode-node
```

For WireGuard exit (interface + automatic peer NAT via `iptables`), connect:

```bash
sudo snap connect diode-node:network-control
sudo snap connect diode-node:firewall-control
sudo snap restart diode-node.service
```

If you do not connect `firewall-control`, set `WIREGUARD_AUTO_NAT=0` and configure NAT on the host (e.g. `scripts/setup-wg-nat.sh`).

## Snap commands

Besides the background service, the snap installs several commands. Arguments you pass after the command name are forwarded to the node (for example `diode-node.rpc Diode.Cmd.status` runs `bin/run elevated rpc Diode.Cmd.status` inside the snap).

| Command | Description |
| --- | --- |
| `diode-node.service` | Relay node daemon (managed with `snap services`) |
| `diode-node.info` | Print node status (wallet, uptime, peers, epoch score) |
| `diode-node.rpc` | Run any RPC expression on the running node |
| `diode-node.flush` | Clear in-memory caches |
| `diode-node.env` | Print effective environment variables |
| `diode-node.shell` | Attach a remote console to the running node |

Service control:

```bash
sudo snap services diode-node
sudo snap start diode-node.service
sudo snap stop diode-node.service
sudo snap restart diode-node.service
```

Status and built-in RPC helpers (no extra arguments needed for `flush`, `info`, and `env`):

```bash
diode-node.info
sudo diode-node.flush
sudo diode-node.env
```

Generic RPC — pass any Elixir expression as arguments (`rpc`, `flush`, `env`, and `shell` require `sudo` because they run as the snap superuser):

```bash
sudo diode-node.rpc Diode.Cmd.status
sudo diode-node.rpc 'Diode.Cmd.configure()'
sudo diode-node.rpc 'IO.inspect(Diode.wallet())'
```

Remote console:

```bash
sudo diode-node.shell
```

After changing snap configuration, apply settings and restart if needed:

```bash
sudo snap set diode-node host=203.0.113.1
sudo snap set diode-node log-level=debug
sudo diode-node.rpc 'Diode.Cmd.configure()'
sudo snap restart diode-node.service
```

Snap config keys use lowercase with hyphens (environment variables use underscores), for example `wireguard-listen-port` maps to `WIREGUARD_LISTEN_PORT`. List current values with `sudo snap get diode-node`.

# Linux Kernel optimization

To optimize Linux for maximum network performance we advise to enable tcp bbr:

```/etc/sysctl.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
```

```/etc/modules-load.d/modules.conf
tcp_bbr
```

And then reboot or 

```bash
sudo modprobe tcp_bbr 
sudo sysctl --system
```

# Operations

## Backup and restore

Before planned maintenance, flush caches and create a snap snapshot:

```bash
sudo diode-node.flush
sudo snap stop diode-node
sudo snap save diode-node
```

When you remove the snap (`sudo snap remove diode-node`), the remove hook automatically archives critical node files (identity, Erlang DNS config, and wallet database) to `/var/backups/diode-node/diode_node_backup_<timestamp>.tar.gz`. The `backup-dir` system-files plug must be connected for this path to work; otherwise rely on `snap saved` within 31 days.

To restore from an automatic backup after reinstalling:

```bash
sudo snap install diode-node
sudo snap stop diode-node.service
sudo snap run --shell diode-node -c 'bin/restore_snap_backup /var/backups/diode-node/diode_node_backup_YYYY-MM-DD_HHMMSS.tar.gz'
sudo snap start diode-node.service
```

## See last service restart reason

When running the snap installation then it's a two step process to see the last service restart reason:

1. Get the timestamp of the last service restart
2. Read the logs around that timestamp

```bash
> systemctl show -p ActiveEnterTimestamp snap.diode-node.service.service
ActiveEnterTimestamp=Mon 2024-12-30 02:57:06 UTC
> journalctl -u snap.diode-node.service.service --since "2024-12-30 02:50:00"
```

