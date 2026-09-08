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

# Development

Contributors and coding agents should read [AGENTS.md](AGENTS.md) before making changes. **Bug fixes and new behavior require regression tests** in the same PR.

```bash
mix deps.get
mix lint
mix test test/path/to/your_test.exs
```

See [docs/testing.md](docs/testing.md) for test layout, `Plug.Test` examples, and isolated test commands.

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

## Remote RPC over SSH

Nodes installed from the release tarball (see `deployment/fabfile.exs`) run out of `/opt/diode_node`
and evaluate one-off expressions with the release CLI:

| Command | Behaviour |
| --- | --- |
| `bin/diode_node rpc 'EXPR'` | Executes `EXPR` **remotely on the running node** (sees live state, needs the node up, a matching `releases/COOKIE` and `RELEASE_DISTRIBUTION`) |
| `bin/diode_node eval 'EXPR'` | Executes `EXPR` on a **new, non-booted node** (no live state, no cookie) |
| `bin/diode_node remote` | Attaches a remote shell (see `./remsh`) |

A failing expression exits non-zero and its output comes back on the same ssh channel, so both
commands are usable from scripts.

### Proper call structure

The one canonical way to call it in a single ssh command line is: the remote command wrapped in
double quotes, the expression wrapped in single quotes, and Elixir string literals in **escaped**
double quotes:

```bash
ssh us1 "/opt/diode_node/bin/diode_node rpc 'IO.puts(\"tes\")'"
```

The node receives `IO.puts("tes")` and prints `tes`. The same structure works for expressions with
spaces, because the single quotes hold them together for the remote shell:

```bash
ssh us1 "/opt/diode_node/bin/diode_node rpc 'IO.inspect(%{a: 1, b: 2})'"
```

Why the escaping looks like that: `ssh HOST CMD ARGS` never execs argv. It joins all arguments with
spaces and hands the resulting string to the remote login shell, so the expression is parsed **twice**
— once locally, once remotely. The outer double quotes only protect the string on the local side, the
inner single quotes protect it on the remote side, and `\"` is what survives *both* parses as a plain
`"` for Elixir.

Do not pass the expression as its own argument and escape the parentheses instead:

```bash
# WRONG: the remote shell eats \( \) and the single quotes, so the node compiles
# IO.puts(tes) and dies with
#   error: undefined variable "tes"
#   ** (CompileError) nofile: cannot compile file (errors have been logged)
ssh us1 /opt/diode_node/bin/diode_node rpc "IO.puts\('tes'\)"
```

Also wrong: dropping the backslashes in front of the string quotes
(`ssh us1 "… rpc 'IO.puts("tes")'"`) — the local shell closes the double quote before `tes`, and the
node again receives `IO.puts(tes)`.

Rules of thumb:

1. Use Elixir binaries (`"tes"`), never charlists (`'tes'` warns since Elixir 1.20).
2. Count escapes for exactly two shell parses — or don't count, use one of the forms below.
3. Keep `$`, backticks and `!` out of expressions that travel inside double quotes, or move them to a
   form that does not expand anything.
4. `rpc` takes exactly **one** argument (the shim forwards only `$2`), so anything past an
   un-quoted space is silently dropped and shows up as a confusing syntax error. Expressions without
   spaces are the least fragile, which is why `deployment/fabfile.exs` sticks to
   `'IO.inspect(Mod.fun(args))'` calls.

### Escaping-free alternatives for complex expressions

```bash
# let printf %q generate the escaping (needs bash locally)
ssh us1 "$(printf '%q ' /opt/diode_node/bin/diode_node rpc 'IO.puts("tes $HOME")')"

# no quoting at all: ship the expression on stdin (multi-line safe, immune to $ and backticks)
printf '%s' 'IO.puts("tes $HOME")' | ssh us1 'expr=$(cat); /opt/diode_node/bin/diode_node rpc "$expr"'
```

Both deliver `IO.puts("tes $HOME")` verbatim, i.e. they print `tes $HOME` instead of expanding it.

### UTF-8 locale

Non-interactive ssh sessions often have no UTF-8 locale on the server, and the CLI node then warns
`the VM is running with native name encoding of latin1 …`. Either give the remote command a locale:

```bash
ssh us1 "export LC_ALL=C.UTF-8; /opt/diode_node/bin/diode_node rpc 'IO.puts(\"tes\")'"
```

… or fix it for every release command (including `rpc`) by exporting `LANG`/`ELIXIR_ERL_OPTIONS="+fnu"`
in `rel/env.sh.eex`, which the release wrapper sources for all subcommands.

Note: snap installs route through `snap/run`, which re-expands the arguments unquoted (`$*`), so the
expression is split **again** at every space: `sudo diode-node.rpc 'IO.puts("a b")'` reaches the node
as `IO.puts("a`. Prefer expressions without spaces (`sudo diode-node.rpc 'Diode.Cmd.status'`) or attach
a shell (`sudo diode-node.shell`).

## See last service restart reason

When running the snap installation then it's a two step process to see the last service restart reason:

1. Get the timestamp of the last service restart
2. Read the logs around that timestamp

```bash
> systemctl show -p ActiveEnterTimestamp snap.diode-node.service.service
ActiveEnterTimestamp=Mon 2024-12-30 02:57:06 UTC
> journalctl -u snap.diode-node.service.service --since "2024-12-30 02:50:00"
```

