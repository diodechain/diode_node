# Vendored TURN stack (in-tree)

## xturn

The TURN implementation is **Hex [xturn 0.1.2](https://hex.pm/packages/xturn) sources**, vendored under:

- `lib/xturn.ex`
- `lib/xturn/`

Upstream does not compile as a **path dependency** on Elixir 1.19 (remote struct expansion in patterns). The in-tree copy uses **fully qualified** struct names (`%XMediaLib.Stun{}`, `%Xirsys.Sockets.Conn{}`, `%Xirsys.Sockets.Socket{}`) in patterns.

`lib/xturn/pipeline.ex` reads `:pipes` at **runtime** via `Application.get_env(:xturn, :pipes, %{})` so `Diode.Turn` can inject `Diode.Turn.Authenticates` after boot.

`Xirsys.XTurn` is not started as a separate OTP application; `TurnService` calls `Xirsys.XTurn.start_servers/0`.

## xmedialib

**Hex [xmedialib 0.1.2](https://hex.pm/packages/xmedialib)** is vendored under **`vendor/xmedialib/`** and referenced from the root `mix.exs` as `{:xmedialib, path: "vendor/xmedialib", override: true}`.

Only **`lib/stun.ex`** is kept (RFC STUN/TURN); other upstream modules (codec, SRTP, ZRTP, RTCP, …) are omitted so the node does not build unused code.

**Diode patches in `stun.ex`:** OTP 28 removes `:crypto.hmac/3` — use **`:crypto.mac(:hmac, :sha, key, data)`** for MESSAGE-INTEGRITY. Replace deprecated **`use Bitwise`** with **`import Bitwise`**.
