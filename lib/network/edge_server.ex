# Diode Server
# Copyright 2021-2025 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.EdgeServer do
  @moduledoc """
  TLS connection registry for device Edge (v2) handlers.

  ## Duplicate wallet registrations

  During handshake, `Common.register_node_clients/6` resolves conflicts with
  `connect_key` (the registry key this connection already held, if any) and
  `actual_key` (the wallet from the peer certificate).

  - `connect_key == actual_key` — terminate the older session (`:kill_clone`) and
    replace the primary `clients` entry.
  - `connect_key != actual_key` — keep **both** TLS sessions alive, including when
    `connect_key` is `nil` (a second device reconnecting under the same wallet).
    The newest handler becomes the primary `clients` entry for `actual_key`; the
    previous pid stays registered via the `pid -> key` reverse index until it exits.

  The former unified `Network.Server` used one resolver for Edge and Peer traffic
  and always killed the stale session when `connect_key` was `nil`, so only one
  edge device per wallet could stay connected. Peer handlers now use
  `Network.PeerServer`, which still rejects or replaces duplicates on `nil`
  `connect_key`.
  """

  use GenServer

  use Network.Common,
    server: [
      handler: Network.EdgeV2,
      name: Network.EdgeV2,
      conflict: :edge
    ]

  defstruct sockets: %{},
            clients: %{},
            ports: [],
            opts: %{},
            pid: nil,
            acceptors: %{},
            self_conns: []
end
