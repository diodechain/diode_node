# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1

defmodule Diode.Turn.AuthenticatesTest do
  use ExUnit.Case, async: false

  @realm "diode"

  setup do
    Application.ensure_all_started(:globals)
    prev_auth = Application.get_env(:xturn, :authentication)

    Application.put_env(:xturn, :authentication, %{
      required: true,
      username: :unused,
      credential: :unused
    })

    start_supervised!(Diode.Turn.CredentialStore)

    device = <<2::160>>
    {:ok, %{username: u, password: p}} = Diode.Turn.CredentialStore.issue_or_get(device)
    hkey = :crypto.hash(:md5, u <> ":" <> @realm <> ":" <> p)
    tid = :binary.decode_unsigned(:crypto.strong_rand_bytes(12))

    raw =
      XMediaLib.Stun.encode(%XMediaLib.Stun{
        class: :request,
        method: :allocate,
        transactionid: tid,
        fingerprint: false,
        key: hkey,
        attrs: [username: u, realm: @realm]
      })

    decoded = %XMediaLib.Stun{
      class: :request,
      method: :allocate,
      transactionid: tid,
      attrs: %{username: u, realm: @realm}
    }

    conn = %Xirsys.Sockets.Conn{
      message: raw,
      decoded_message: decoded,
      force_auth: false
    }

    on_exit(fn -> Application.put_env(:xturn, :authentication, prev_auth) end)

    {:ok, conn: conn, username: u, password: p, hkey: hkey, tid: tid}
  end

  test "process accepts valid MESSAGE-INTEGRITY", %{conn: conn} do
    out = Diode.Turn.Authenticates.process(conn)
    refute out.halt
    assert %XMediaLib.Stun{} = out.decoded_message
  end

  test "process rejects wrong integrity", %{username: u, tid: tid} do
    bad_key = :crypto.hash(:md5, "wrong:" <> @realm <> ":cred")

    raw =
      XMediaLib.Stun.encode(%XMediaLib.Stun{
        class: :request,
        method: :allocate,
        transactionid: tid,
        fingerprint: false,
        key: bad_key,
        attrs: [username: u, realm: @realm]
      })

    conn = %Xirsys.Sockets.Conn{
      message: raw,
      decoded_message: %XMediaLib.Stun{
        class: :request,
        method: :allocate,
        transactionid: tid,
        attrs: %{username: u, realm: @realm}
      },
      force_auth: false
    }

    out = Diode.Turn.Authenticates.process(conn)
    assert out.halt
  end
end
