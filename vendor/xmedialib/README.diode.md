# Diode vendored xmedialib

Upstream: [Hex xmedialib 0.1.2](https://hex.pm/packages/xmedialib) / [xirsys/xmedialib](https://github.com/xirsys/xmedialib).

**Diode scope:** Only **`lib/stun.ex`** is kept (RFC 5389 STUN/TURN). Other upstream modules (codec, SRTP, ZRTP, RTCP, …) are removed so the node does not compile unused code or hit OTP 28 deprecations there.

**Patches in `stun.ex`:**

- MESSAGE-INTEGRITY uses `:crypto.mac(:hmac, :sha, key, data)` instead of removed `:crypto.hmac/3`.
- `import Bitwise` instead of deprecated `use Bitwise`.

See `docs/vendoring-xturn.md` in the diode node repo.
