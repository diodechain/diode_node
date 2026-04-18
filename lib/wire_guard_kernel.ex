# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule WireGuardKernel do
  @moduledoc """
  Kernel-level helpers for the WireGuard exit node service.

  `wireguardex` only configures the WG-specific bits of the interface (private key,
  listen port, peers). The kernel will not bind the WG UDP socket nor route inner packets
  unless we also:

    1. set the link `IFF_UP` (so the kernel calls `wg_open()` and binds the UDP listener),
    2. assign a gateway IP/CIDR on the interface (so replies from the egress NAT can be
       routed back to peers),
    3. enable IPv4 forwarding (`/proc/sys/net/ipv4/ip_forward = 1`),
    4. install a MASQUERADE rule for the tunnel subnet (typically out of band, see
       `scripts/setup-wg-nat.sh`).

  Steps 1–3 are done **directly from BEAM** because the supervised BEAM holds
  `CAP_NET_ADMIN` (typically via `setcap cap_net_admin+ep` or the snap `network-control`
  plug). Erlang's built-in `:socket` module can open `AF_NETLINK` / `NETLINK_ROUTE` from
  inside the VM, so no shell-out is needed (and no caps need to leak into spawned children
  — by default they wouldn't get any).

  Step 4 (MASQUERADE / FORWARD) is applied automatically on Linux when an `iptables` wrapper
  succeeds — see `WireGuardNat` (it picks legacy vs nft to match the host). If that fails
  (common without root), run `sudo scripts/setup-wg-nat.sh` once; the `iptables` binary
  typically cannot use `CAP_NET_ADMIN` from the BEAM alone.
  """

  require Logger
  import Bitwise

  # AF_NETLINK = 16, NETLINK_ROUTE = 0
  @af_netlink 16
  @netlink_route 0

  # nlmsg flags
  @nlm_f_request 0x0001
  @nlm_f_ack 0x0004
  @nlm_f_replace 0x0100
  @nlm_f_create 0x0400

  # nlmsg types we use
  @rtm_newlink 16
  @rtm_newaddr 20
  @nlmsg_error 2
  @nlmsg_done 3

  # ifinfomsg flags
  @iff_up 1

  # rtnetlink attribute types
  @ifla_ifname 3
  @ifa_address 1
  @ifa_local 2

  # AF_INET / AF_UNSPEC
  @af_inet 2
  @af_unspec 0

  @doc """
  Best-effort, idempotent kernel-level WG bring-up:

    * sets `IFF_UP` on `iface`,
    * assigns `ipv4_cidr` (e.g. `"10.0.0.1/24"`) on `iface` (replaces if it already exists),
    * enables IPv4 forwarding.

  Returns `:ok` on full success or `{:error, term}` describing the first failing step.
  Each step logs its result so transient failures are visible without re-running.
  """
  def setup_link(iface, ipv4_cidr) when is_binary(iface) and is_binary(ipv4_cidr) do
    with {:ok, ifindex} <- if_index(iface),
         :ok <- bring_link_up(iface, ifindex),
         :ok <- assign_address(ifindex, iface, ipv4_cidr),
         :ok <- enable_ip_forwarding() do
      :ok
    end
  end

  @doc """
  Bring `iface` up via `RTM_NEWLINK` with `IFF_UP` set in both `flags` and `change`. Idempotent.
  """
  def bring_link_up(iface, ifindex) when is_binary(iface) and is_integer(ifindex) do
    # ifinfomsg = u8 family + u8 pad + u16 type + s32 index + u32 flags + u32 change
    payload = <<
      @af_unspec::8,
      0::8,
      0::little-16,
      ifindex::little-signed-32,
      @iff_up::little-32,
      @iff_up::little-32
    >>

    ifname_attr = nl_attr(@ifla_ifname, iface <> <<0>>)
    body = payload <> ifname_attr
    flags = @nlm_f_request ||| @nlm_f_ack

    case netlink_request(@rtm_newlink, flags, body) do
      :ok ->
        Logger.info("WireGuardKernel: brought interface #{iface} (idx=#{ifindex}) up via netlink")
        :ok

      {:error, reason} = err ->
        Logger.error(
          "WireGuardKernel: failed to bring interface #{iface} up via netlink: #{inspect(reason)}"
        )

        err
    end
  end

  @doc """
  Idempotently assign `cidr` (e.g. `"10.0.0.1/24"`) to `iface`. Uses `NLM_F_REPLACE` so
  re-running on an interface that already has the address (e.g. after `svc -k`) is fine.
  """
  def assign_address(ifindex, iface, cidr)
      when is_integer(ifindex) and is_binary(iface) and is_binary(cidr) do
    with {:ok, {addr_bytes, prefix}} <- parse_ipv4_cidr(cidr) do
      # ifaddrmsg = u8 family + u8 prefixlen + u8 flags + u8 scope + u32 index
      payload = <<
        @af_inet::8,
        prefix::8,
        0::8,
        0::8,
        ifindex::little-32
      >>

      attrs = nl_attr(@ifa_local, addr_bytes) <> nl_attr(@ifa_address, addr_bytes)
      body = payload <> attrs
      flags = @nlm_f_request ||| @nlm_f_ack ||| @nlm_f_create ||| @nlm_f_replace

      case netlink_request(@rtm_newaddr, flags, body) do
        :ok ->
          Logger.info("WireGuardKernel: assigned #{cidr} to interface #{iface} (idx=#{ifindex})")

          :ok

        {:error, reason} = err ->
          Logger.error(
            "WireGuardKernel: failed to assign #{cidr} to #{iface}: #{inspect(reason)}"
          )

          err
      end
    end
  end

  @doc """
  Write `1` to `/proc/sys/net/ipv4/ip_forward`. With `CAP_NET_ADMIN`, BEAM may write to
  net-related sysctls regardless of the file's DAC mode.
  """
  def enable_ip_forwarding do
    case File.write("/proc/sys/net/ipv4/ip_forward", "1") do
      :ok ->
        Logger.info("WireGuardKernel: net.ipv4.ip_forward set to 1")
        :ok

      {:error, reason} = err ->
        Logger.error(
          "WireGuardKernel: failed to enable IPv4 forwarding (need CAP_NET_ADMIN on BEAM): #{inspect(reason)}"
        )

        err
    end
  end

  @doc """
  Resolve an interface name to its kernel index using OTP's built-in `:net.if_name2index/1`.
  """
  def if_index(iface) when is_binary(iface) do
    case :net.if_name2index(String.to_charlist(iface)) do
      {:ok, idx} -> {:ok, idx}
      {:error, reason} -> {:error, {:if_name2index, iface, reason}}
    end
  end

  defp nl_attr(type, value) when is_integer(type) and is_binary(value) do
    len = 4 + byte_size(value)
    pad = nl_pad(len)
    <<len::little-16, type::little-16>> <> value <> :binary.copy(<<0>>, pad)
  end

  defp nl_pad(len), do: rem(4 - rem(len, 4), 4)

  # Send a single netlink request and wait for the matching ACK. Returns `:ok` on
  # `NLMSG_ERROR` with errno=0 (the kernel's "ACK"), `{:error, {:nl, errno}}` otherwise.
  # sockaddr_nl is 12 bytes: u16 family + u16 pad + u32 pid + u32 groups (host byte order).
  # Erlang's :socket sockaddr_native takes `family` separately and `addr` = the rest (10 bytes).
  @nl_addr %{family: @af_netlink, addr: <<0::16, 0::little-32, 0::little-32>>}

  defp netlink_request(type, flags, body) do
    seq = :erlang.unique_integer([:positive, :monotonic])
    seq32 = rem(seq, 0xFFFFFFFF) + 1
    msg = build_nlmsg(type, flags, seq32, 0, body)

    case open_route_socket() do
      {:ok, sock} ->
        try do
          with :ok <- :socket.sendto(sock, msg, @nl_addr),
               {:ok, reply} <- recv_until_seq(sock, seq32, 5_000) do
            parse_ack(reply, seq32)
          end
        after
          _ = :socket.close(sock)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp open_route_socket do
    case :socket.open(@af_netlink, :raw, @netlink_route) do
      {:ok, sock} ->
        case :socket.bind(sock, @nl_addr) do
          :ok ->
            {:ok, sock}

          {:error, reason} ->
            :socket.close(sock)
            {:error, {:netlink_bind, reason}}
        end

      {:error, reason} ->
        {:error, {:netlink_open, reason}}
    end
  end

  defp build_nlmsg(type, flags, seq, pid, body) do
    total = 16 + byte_size(body)

    <<
      total::little-32,
      type::little-16,
      flags::little-16,
      seq::little-32,
      pid::little-32
    >> <> body
  end

  defp recv_until_seq(sock, _expected_seq, timeout_ms) do
    case :socket.recvfrom(sock, 65_536, [], timeout_ms) do
      {:ok, {_from, data}} -> {:ok, data}
      {:error, reason} -> {:error, {:netlink_recv, reason}}
    end
  end

  # Parse a single nlmsghdr; if it's an NLMSG_ERROR with err=0, treat as ACK.
  # If multiple messages are bundled, walk to the matching seq.
  defp parse_ack(<<>>, _seq), do: {:error, {:nl_ack_missing}}

  defp parse_ack(data, expected_seq) do
    <<len::little-32, type::little-16, _flags::little-16, seq::little-32, _pid::little-32,
      rest::binary>> = data

    payload_size = len - 16
    <<payload::binary-size(payload_size), tail::binary>> = rest

    cond do
      type == @nlmsg_error and seq == expected_seq ->
        <<errno::little-signed-32, _orig::binary>> = payload

        if errno == 0 do
          :ok
        else
          {:error, {:nl, errno_to_atom(errno), errno}}
        end

      type == @nlmsg_done ->
        :ok

      tail == <<>> ->
        # No matching ACK message; treat as silent success (kernel sometimes
        # omits ACK if NLM_F_ACK was not honoured, but we always set it).
        {:error, {:nl_unexpected, type}}

      true ->
        parse_ack(tail, expected_seq)
    end
  end

  defp parse_ipv4_cidr(cidr) do
    case String.split(cidr, "/", parts: 2) do
      [ip, prefix_str] ->
        with {prefix, ""} when prefix in 0..32 <- Integer.parse(prefix_str),
             [_, _, _, _] = parts <- String.split(ip, "."),
             {:ok, bytes} <- ipv4_bytes(parts) do
          {:ok, {bytes, prefix}}
        else
          _ -> {:error, {:bad_cidr, cidr}}
        end

      _ ->
        {:error, {:bad_cidr, cidr}}
    end
  end

  defp ipv4_bytes(parts) do
    try do
      bytes =
        parts
        |> Enum.map(fn p ->
          {n, ""} = Integer.parse(p)
          true = n in 0..255
          <<n::8>>
        end)
        |> Enum.reduce(<<>>, fn b, acc -> acc <> b end)

      {:ok, bytes}
    rescue
      _ -> {:error, :bad_ipv4}
    end
  end

  # Map common netlink errnos to readable atoms.
  defp errno_to_atom(errno) do
    case -errno do
      1 -> :eperm
      2 -> :enoent
      13 -> :eacces
      16 -> :ebusy
      17 -> :eexist
      19 -> :enodev
      22 -> :einval
      _ -> :unknown
    end
  end
end
