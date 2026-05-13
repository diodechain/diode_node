# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1

defmodule Network.RpcDocs do
  @moduledoc false

  @doc """
  Static documentation for all `dio_*` JSON-RPC methods exposed by the relay node.
  Used by `GET /api` (see `Network.RpcHttp`).
  """
  def all do
    [
      intro(),
      dio_version(),
      dio_network(),
      dio_get_object(),
      dio_get_node(),
      dio_traffic(),
      dio_tickets(),
      dio_usage(),
      dio_usage_history(),
      dio_check_connectivity(),
      dio_proxy(),
      dio_accounts(),
      dio_code_groups(),
      dio_supply(),
      dio_get_pool(),
      dio_edgev2(),
      dio_ticket(),
      dio_message(),
      dio_wireguard_open(),
      dio_wireguard_close(),
      dio_turn_open()
    ]
  end

  defp intro do
    %{
      section: "Basics",
      slug: "introduction",
      title: "Introduction",
      method: nil,
      auth: nil,
      description: """
      Diode relay nodes expose JSON-RPC 2.0 over HTTP(S). Send a POST request with \
      Content-Type: application/json to the node root URL (same path as eth_* calls; \
      typically / on port 8545 or 8443). Successful responses include result; \
      errors use HTTP 4xx/5xx and may include a JSON-RPC error object. \
      Some responses add x-diode-signature and x-diode-sender headers (see proxied calls).
      """,
      params: [],
      example_request:
        pretty(%{
          "jsonrpc" => "2.0",
          "method" => "dio_version",
          "params" => [],
          "id" => 1
        }),
      example_response:
        pretty(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "result" => %{
            "version" => "2.2.3",
            "description" => "v2.2.3",
            "features" => "turn,wg_exit"
          }
        })
    }
  end

  defp dio_version do
    %{
      section: "Basics",
      slug: "dio_version",
      title: "dio_version",
      method: "dio_version",
      auth: :none,
      description:
        "Returns this node's software version, description string, and advertised feature flags.",
      params: [],
      example_request: rpc("dio_version", []),
      example_response:
        ok(%{
          "version" => "2.2.3",
          "description" => "v2.2.3-3-g5973c29",
          "features" => "turn,wg_exit"
        })
    }
  end

  defp dio_network do
    %{
      section: "Node",
      slug: "dio_network",
      title: "dio_network",
      method: "dio_network",
      auth: :none,
      description: """
      Lists known Diode relay peers from Kademlia plus currently connected peers. \
      Each entry includes `node_id`, connection state, retry metadata, and a decoded `node` object when available.
      """,
      params: [],
      example_request: rpc("dio_network", []),
      example_response:
        ok([
          %{
            "connected" => true,
            "last_seen" => "0x6a04ebed",
            "last_error" => "0x00",
            "node_id" => "0x100c283fadc36f008a85cc1aa40a6e5de6115ef8",
            "node" => ["server", "198.51.100.1", "0xa056", "0xc76f", "2.2.3", [], "0x01…"],
            "retries" => "0x00"
          }
        ])
    }
  end

  defp dio_get_object do
    %{
      section: "Node",
      slug: "dio_getObject",
      title: "dio_getObject",
      method: "dio_getObject",
      auth: :none,
      description:
        "Looks up a Kademlia object by content hash and returns it as an RLP-encoded list (hex).",
      params: [
        %{
          name: "key",
          type: "hex string",
          doc: "32-byte object key, hex-encoded (with or without 0x)."
        }
      ],
      example_request: rpc("dio_getObject", ["0xabcdef…"]),
      example_response: ok(["object", "0x…", "0x…"])
    }
  end

  defp dio_get_node do
    %{
      section: "Node",
      slug: "dio_getNode",
      title: "dio_getNode",
      method: "dio_getNode",
      auth: :none,
      description:
        "Returns the server object for a Diode node id (20-byte address / node id), RLP-encoded list as JSON array.",
      params: [
        %{name: "node_id", type: "hex string", doc: "20-byte node address, hex-encoded."}
      ],
      example_request: rpc("dio_getNode", ["0x100c283fadc36f008a85cc1aa40a6e5de6115ef8"]),
      example_response: ok(["server", "198.51.100.1", "0xa056", "0xc76f", "2.2.3", [], "0x01…"])
    }
  end

  defp dio_traffic do
    %{
      section: "Metrics",
      slug: "dio_traffic",
      title: "dio_traffic",
      method: "dio_traffic",
      auth: :none,
      description: """
      Aggregates ticket usage for a chain id (and optional epoch). \
      Response includes `chain_id`, `epoch`, `epoch_time`, and a `fleets` map keyed by fleet contract with totals and on-chain fleet state at the resolved block.
      """,
      params: [
        %{
          name: "chain_id",
          type: "hex or integer",
          doc: "Target chain id (e.g. Moonbeam `15` or `\"0xf\"`)."
        },
        %{
          name: "epoch",
          type: "hex | integer | omitted",
          doc: "Optional epoch; defaults to current epoch for the chain."
        }
      ],
      example_request: rpc("dio_traffic", ["0xf"]),
      example_response:
        ok(%{
          "chain_id" => 15,
          "epoch" => 12_345,
          "epoch_time" => 1_700_000_000,
          "fleets" => %{
            "0xFleet…" => %{
              "fleet" => "0xFleet…",
              "total_tickets" => 42,
              "total_bytes" => 1_024,
              "total_connections" => 3,
              "total_score" => 100,
              "state" => %{}
            }
          }
        })
    }
  end

  defp dio_tickets do
    %{
      section: "Metrics",
      slug: "dio_tickets",
      title: "dio_tickets",
      method: "dio_tickets",
      auth: :none,
      description:
        "Returns all ticket objects for a chain and epoch as hex-encoded binaries, plus chain/epoch metadata.",
      params: [
        %{name: "chain_id", type: "hex or integer", doc: "Target chain id."},
        %{
          name: "epoch",
          type: "hex | integer | omitted",
          doc: "Optional epoch; defaults to current epoch."
        }
      ],
      example_request: rpc("dio_tickets", ["0xf"]),
      example_response:
        ok(%{
          "chain_id" => 15,
          "epoch" => 12_345,
          "epoch_time" => 1_700_000_000,
          "tickets" => ["0x0102…", "0x0304…"]
        })
    }
  end

  defp dio_usage do
    %{
      section: "Metrics",
      slug: "dio_usage",
      title: "dio_usage",
      method: "dio_usage",
      auth: :none,
      description:
        "Local node counters: wallet address, configured name, uptime, connected Edge devices, and edge traffic in/out (values are hex-encoded integers in JSON).",
      params: [],
      example_request: rpc("dio_usage", []),
      example_response:
        ok(%{
          "address" => "0x937c492a77ae90de971986d003ffbc5f8bb2232c",
          "name" => "relay.example",
          "uptime" => "0x1b0c26f6",
          "devices" => "0xf1",
          "incoming" => "0x4f1126",
          "outgoing" => "0x49a955",
          "total" => "0x98ba7b"
        })
    }
  end

  defp dio_usage_history do
    %{
      section: "Metrics",
      slug: "dio_usageHistory",
      title: "dio_usageHistory",
      method: "dio_usageHistory",
      auth: :none,
      description:
        "Time-bucketed history of internal stats between Unix timestamps `from` and `to`, with `stepping` seconds per bucket. Map keys are stringified stat names.",
      params: [
        %{name: "from", type: "integer", doc: "Unix timestamp (seconds), start inclusive."},
        %{name: "to", type: "integer", doc: "Unix timestamp (seconds), end inclusive."},
        %{name: "stepping", type: "integer", doc: "Bucket width in seconds."}
      ],
      example_request: rpc("dio_usageHistory", [1_719_312_049, 1_719_312_149, 10]),
      example_response:
        ok(%{
          1_719_312_049 => %{"edge_traffic_in" => 100, "edge_traffic_out" => 200},
          1_719_312_059 => %{"edge_traffic_in" => 110, "edge_traffic_out" => 210}
        })
    }
  end

  defp dio_check_connectivity do
    %{
      section: "Metrics",
      slug: "dio_checkConnectivity",
      title: "dio_checkConnectivity",
      method: "dio_checkConnectivity",
      auth: :none,
      description: """
      Triggers or returns the latest outbound connectivity check against the Diode monitor service. \
      May return cached `{timestamp, status}` while a new check runs; `status` can be a decoded JSON map with `ip` and `ports` or an error string.
      """,
      params: [],
      example_request: rpc("dio_checkConnectivity", []),
      example_response:
        ok(%{"timestamp" => 1_700_000_000, "status" => %{"ip" => "198.51.100.2", "ports" => %{}}})
    }
  end

  defp dio_proxy do
    %{
      section: "Proxy",
      slug: "dio_proxy",
      title: "dio_proxy and dio_proxy2",
      method: "dio_proxy|<method>",
      auth: :none,
      description: """
      Forward a supported `dio_*` call to another relay identified by the first parameter (20-byte address, hex). \
      **`dio_proxy|`** relays without signature verification on the reply. **`dio_proxy2|`** requires valid \
      `x-diode-sender` / `x-diode-signature` headers on the upstream response. \
      Allowed inner methods: `dio_checkConnectivity`, `dio_getObject`, `dio_getNode`, `dio_traffic`, `dio_tickets`, `dio_usage`, `dio_usageHistory`.
      """,
      params: [
        %{name: "node", type: "hex string", doc: "Target relay node address (20 bytes)."},
        %{
          name: "…",
          type: "inner params",
          doc: "Remaining parameters are passed to the inner method after `node`."
        }
      ],
      example_request: rpc("dio_proxy|dio_usage", ["0xf188acf5e19f0ac06b4b60d77b477e0ef8c658f4"]),
      example_response:
        ok(%{
          "address" => "0x…",
          "name" => "…",
          "uptime" => "0x…",
          "devices" => "0x…",
          "incoming" => "0x…",
          "outgoing" => "0x…",
          "total" => "0x…"
        })
    }
  end

  defp dio_accounts do
    %{
      section: "Chain (Diode L1)",
      slug: "dio_accounts",
      title: "dio_accounts",
      method: "dio_accounts",
      auth: :none,
      description:
        "Proxied to the configured Diode L1 JSON-RPC provider; parameters follow that RPC (block tags like `latest` are resolved to a numeric block on this node).",
      params: [
        %{
          name: "params",
          type: "array",
          doc: "Provider-specific; see Diode L1 / Geth-style docs."
        }
      ],
      example_request: rpc("dio_accounts", []),
      example_response: ok([])
    }
  end

  defp dio_code_groups do
    %{
      section: "Chain (Diode L1)",
      slug: "dio_codeGroups",
      title: "dio_codeGroups",
      method: "dio_codeGroups",
      auth: :none,
      description:
        "Proxied to Diode L1 — fleet / code group listing for the given block reference.",
      params: [
        %{
          name: "block",
          type: "hex string",
          doc: "Block number or tag, hex-encoded (e.g. `\"0x16\"`)."
        }
      ],
      example_request: rpc("dio_codeGroups", ["0x16"]),
      example_response: ok(%{})
    }
  end

  defp dio_supply do
    %{
      section: "Chain (Diode L1)",
      slug: "dio_supply",
      title: "dio_supply",
      method: "dio_supply",
      auth: :none,
      description:
        "Proxied to Diode L1 — aggregate supply / balance accounting for the given block.",
      params: [%{name: "block", type: "hex string", doc: "Block number or tag, hex-encoded."}],
      example_request: rpc("dio_supply", ["0x16"]),
      example_response: ok(%{})
    }
  end

  defp dio_get_pool do
    %{
      section: "Chain (Diode L1)",
      slug: "dio_getPool",
      title: "dio_getPool",
      method: "dio_getPool",
      auth: :none,
      description:
        "Proxied to Diode L1 — pool state for staking / rewards (exact params depend on the chain contract ABI).",
      params: [
        %{
          name: "params",
          type: "array",
          doc: "Arguments forwarded verbatim to the remote `dio_getPool` RPC."
        }
      ],
      example_request: rpc("dio_getPool", ["0x16"]),
      example_response: ok(nil)
    }
  end

  defp dio_edgev2 do
    %{
      section: "Edge protocol",
      slug: "dio_edgev2",
      title: "dio_edgev2",
      method: "dio_edgev2",
      auth: :none,
      description: """
      Low-level Edge v2 transport: one RLP message frame, hex-encoded, passed to `Network.EdgeV2`. \
      Used by native clients; prefer WebSocket `dio_ticket` / `dio_message` for device workflows over HTTP.
      """,
      params: [
        %{name: "message", type: "hex string", doc: "RLP-encoded Edge v2 message."}
      ],
      example_request: rpc("dio_edgev2", ["0x…"]),
      example_response: ok("0x…")
    }
  end

  defp dio_ticket do
    %{
      section: "Device (WebSocket)",
      slug: "dio_ticket",
      title: "dio_ticket",
      method: "dio_ticket",
      auth: :session,
      description: """
      **WebSocket only** in practice: validates a v2 ticket, binds the device address to the connection process, \
      and subscribes to push events for that device. On HTTP this does not persist a session. \
      On success `result` is `null`. Errors use JSON-RPC-style objects (e.g. invalid epoch, too many bytes).
      """,
      params: [
        %{
          name: "ticket",
          type: "hex string",
          doc: "Hex-encoded binary ticket (RLP ticketv2 payload)."
        }
      ],
      example_request: rpc("dio_ticket", ["0x0102…"]),
      example_response: ok(nil)
    }
  end

  defp dio_message do
    %{
      section: "Device (WebSocket)",
      slug: "dio_message",
      title: "dio_message",
      method: "dio_message",
      auth: :device,
      description: """
      Sends a payload to another device via Edge v2. Requires a prior successful `dio_ticket` on the **same WebSocket**. \
      Optional third argument: metadata object. Destination must be 20 bytes (hex).
      """,
      params: [
        %{name: "destination", type: "hex string", doc: "20-byte recipient device address."},
        %{name: "payload", type: "hex string", doc: "Opaque message bytes."},
        %{name: "metadata", type: "object", doc: "Optional JSON object (third parameter)."}
      ],
      example_request: rpc("dio_message", ["0xRecipient…", "0xDEADBEEF"]),
      example_response: ok(nil)
    }
  end

  defp dio_wireguard_open do
    %{
      section: "Device (WebSocket)",
      slug: "dio_wireguard_open",
      title: "dio_wireguard_open",
      method: "dio_wireguard_open",
      auth: :device,
      description: """
      Registers a WireGuard peer for the authenticated device. Returns session info: \
      `server_public_key` (Base64), `endpoint_host`, `listen_port` (JSON number), `client_address`, etc. \
      Requires prior `dio_ticket` on the same connection. Returns `not authenticated` or feature-disabled errors when applicable.
      """,
      params: [
        %{
          name: "public_key",
          type: "hex string",
          doc: "32-byte WireGuard public key, hex-encoded."
        }
      ],
      example_request: rpc("dio_wireguard_open", ["0x" <> String.duplicate("ab", 32)]),
      example_response:
        ok(%{
          "server_public_key" => "b64…",
          "endpoint_host" => "relay.example",
          "listen_port" => 51_820,
          "client_address" => "10.0.0.2/32"
        })
    }
  end

  defp dio_wireguard_close do
    %{
      section: "Device (WebSocket)",
      slug: "dio_wireguard_close",
      title: "dio_wireguard_close",
      method: "dio_wireguard_close",
      auth: :device,
      description:
        "Removes the WireGuard peer for the authenticated device. Requires prior `dio_ticket` on the same WebSocket.",
      params: [],
      example_request: rpc("dio_wireguard_close", []),
      example_response: ok(nil)
    }
  end

  defp dio_turn_open do
    %{
      section: "Device (WebSocket)",
      slug: "dio_turn_open",
      title: "dio_turn_open",
      method: "dio_turn_open",
      auth: :device,
      description: """
      Issues TURN credentials for the authenticated device: username, `credential` (password), `urls`, `realm`, \
      `ttl_seconds`, `expires_at`. Requires prior `dio_ticket` on the same WebSocket and TURN enabled on the node.
      """,
      params: [],
      example_request: rpc("dio_turn_open", []),
      example_response:
        ok(%{
          "username" => "…",
          "credential" => "…",
          "urls" => ["turn:relay.example:3478?transport=udp"],
          "realm" => "diode",
          "ttl_seconds" => 3600,
          "expires_at" => 1_700_036_000
        })
    }
  end

  defp rpc(method, params) do
    pretty(%{"jsonrpc" => "2.0", "method" => method, "params" => params, "id" => 1})
  end

  defp ok(result) do
    pretty(%{"jsonrpc" => "2.0", "id" => 1, "result" => result})
  end

  defp pretty(term), do: Poison.encode!(term)
end
