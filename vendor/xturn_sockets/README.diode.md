# Diode vendored xturn_sockets

Upstream: [Hex xturn_sockets 0.1.1](https://hex.pm/packages/xturn_sockets) / [xirsys/xturn-sockets](https://github.com/xirsys/xturn-sockets).

**Diode patches:**

- Elixir 1.20: pin `required_size` in `Xirsys.Sockets.Socket.process_data/5` (`binary-size(^required_size)`).

See `docs/vendoring-xturn.md` in the diode node repo.
