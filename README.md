![diode logo](https://diode.io/images/logo-trans.svg)
> ### Secure. Super Light. Web3. 
> EVM anchored secure communication network

# Diode Traffic Gateway

Traffic Gateways should always be setup on publicly reachable interfaces with a public IP. If the Node is not reachable from other nodes it might eventually blocked. 

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

# Pre-Requisites

* Erlang OTP 25
* Elixir 1.15
* make & autoconf & libtool-bin & gcc & g++ & boost
* daemontools

# Building

```bash
mix deps.get
mix compile
```

## Building on macOS

On macOS after installing boost with brew you might need to add it to the environment variables, so the compiler can find it:

```bash
brew install boost
export CFLAGS=-I`brew --prefix boost`/include 
export LDFLAGS=-L`brew --prefix boost`/lib
```

# Running tests

```bash
mix test
```

# Running

```
supervise .
```

# Optimizing Linux

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

