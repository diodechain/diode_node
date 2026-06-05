# Vendored TURN stack (in-tree)

## xturn

The TURN implementation is **Hex [xturn 0.1.2](https://hex.pm/packages/xturn) sources**, vendored under:

- `lib/xturn.ex`
- `lib/xturn/`

Upstream does not compile as a **path dependency** on Elixir 1.19+ (remote struct expansion in patterns). The in-tree copy uses **fully qualified** struct names (`%XMediaLib.Stun{}`, `%Xirsys.Sockets.Conn{}`, `%Xirsys.Sockets.Socket{}`) in patterns.

`lib/xturn/pipeline.ex` reads `:pipes` at **runtime** via `Application.get_env(:xturn, :pipes, %{})` so `Diode.Turn` can inject `Diode.Turn.Authenticates` after boot.

`Xirsys.XTurn` is not started as a separate OTP application; `TurnService` calls `Xirsys.XTurn.start_servers/0`.

## xmedialib

**Hex [xmedialib 0.1.2](https://hex.pm/packages/xmedialib)** is vendored under **`vendor/xmedialib/`** and referenced from the root `mix.exs` as `{:xmedialib, path: "vendor/xmedialib", override: true}`.

Only **`lib/stun.ex`** is kept (RFC STUN/TURN); other upstream modules (codec, SRTP, ZRTP, RTCP, …) are omitted so the node does not build unused code.

**Diode patches in `stun.ex`:**

- OTP 28 removes `:crypto.hmac/3` — use **`:crypto.mac(:hmac, :sha, key, data)`** for MESSAGE-INTEGRITY.
- Replace deprecated **`use Bitwise`** with **`import Bitwise`**.
- Elixir 1.20: read `priv/turn-attrs.txt` at compile time with **`@attr_defs`** so duplicate attribute names (e.g. `alternate_server`) get one `encode_attribute/3` each while decode/stringify keep every type id.
- Elixir 1.20: **`File.stream!(path, line, modes)`** argument order; pin **`^var`** in `binary-size/1` matches where required.

## xturn_sockets

**Hex [xturn_sockets 0.1.1](https://hex.pm/packages/xturn_sockets)** is vendored under **`vendor/xturn_sockets/`** as `{:xturn_sockets, path: "vendor/xturn_sockets", override: true}`.

**Diode patches:** Elixir 1.20 pin operator in `process_data/5` bitstring match (`binary-size(^required_size)`).
