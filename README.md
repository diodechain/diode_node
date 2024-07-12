![diode logo](https://diode.io/images/logo-trans.svg)
> ### Secure. Super Light. Web3. 

# Diode Network Relay Node

Relay nodes are at the heart of Diodes decentralized infrastructure network. Each node helps devices to communicate securely and efficiently through the Diode network. More nodes in more regions mean more available bandwidth for a growing network.

When deploying a node it should be setup on publicly reachable interfaces with a public IP. If the Node is not reachable from other nodes it might eventually get blocked and not receive any traffic. Nodes are gaining reputation over time when they stay up and available.

# Getting Started

To get started with the diode node install the latest snap release:

```bash
sudo snap install diode-node
```

## Snap Configuration

After installation all configuration values are available via the snap config system:

```bash
sudo snap get diode-node
```

# Default Ports

TCP port bindings can be controlled through environment variables. The default bindings are:

| Variable     | Description                       | Default Port(s) |
| --------     | -----------                       | ---- |
| `RPC_PORT`   | Ethereum JSON API endpoint        | 8545
| `RPCS_PORT`  | SSL version of `RPC_PORT`*        | 8443
| `EDGE2_PORT` | Client Communication Port         | 41046,443,993,1723,10000
| `PEER2_PORT`  | Miner-To-Miner Communication Port | 51054

`RPCS_PORT` is only used & needed for access from Web2 services such as the blockchain explorer at https://diode.io/prenet/ - the port can be ignored in most deployments.

`EDGE2_PORT` and `PEER2_PORT` support multiple port numbers given by a comma separated list.

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

