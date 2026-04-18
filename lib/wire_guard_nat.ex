# Diode Server
# Copyright 2021-2026 Diode
# Licensed under the Diode License, Version 1.1
defmodule WireGuardNat do
  @moduledoc """
  Installs SNAT/MASQUERADE and FORWARD accept rules so WireGuard peers can reach the public
  internet through the host.

  `WireGuardKernel` enables IPv4 forwarding and assigns the tunnel gateway IP, but the kernel
  does not NAT `10.0.0.x` traffic onto the WAN interface. That requires netfilter rules — the
  same ones as `scripts/setup-wg-nat.sh`.

  When the BEAM process can run `iptables` successfully (typically **root**, or a
  capability-equipped wrapper), this module applies those rules idempotently at WireGuard
  bring-up. Otherwise it logs a warning; operators must run:

      sudo scripts/setup-wg-nat.sh

  Set `WIREGUARD_AUTO_NAT=0` to skip automatic installation (e.g. you manage firewall elsewhere).

  ## `iptables` backend (legacy vs nft)

  Docker and many hosts still use **iptables-legacy** while `iptables-nft` writes to a different
  netfilter path. If we install MASQUERADE only in nft, counters stay at zero and peers cannot
  egress. This module probes `iptables-nft` for the kernel warning *iptables-legacy tables present*
  and, when seen, prefers `iptables-legacy` (then `iptables`, then `iptables-nft`). Otherwise it
  prefers the distribution `iptables` entrypoint first (Debian `update-alternatives`), matching
  `scripts/setup-wg-nat.sh`.
  """

  require Logger

  @iptables_try_legacy_first ~w(iptables-legacy iptables iptables-nft)
  @iptables_try_default_first ~w(iptables iptables-legacy iptables-nft)

  @doc """
  Best-effort NAT setup for Linux. Returns `:ok` if skipped (non-Linux or auto NAT disabled) or
  if rules were installed; `{:error, term}` if installation failed (caller may still treat WG as up).
  """
  @spec maybe_setup(map()) :: :ok | {:error, term()}
  def maybe_setup(%{interface: iface, tunnel_subnet: subnet})
      when is_binary(iface) and is_binary(subnet) do
    cond do
      :os.type() != {:unix, :linux} ->
        :ok

      auto_nat_disabled?() ->
        Logger.info("WireGuardNat: skipped (WIREGUARD_AUTO_NAT is 0/false/off)")
        :ok

      true ->
        case setup_linux_iptables(subnet, iface) do
          :ok ->
            Logger.info(
              "WireGuardNat: MASQUERADE + FORWARD rules installed (or already present) for #{subnet} dev #{iface}"
            )

            :ok

          {:error, _} = err ->
            {msg, _} = format_nat_warning(err)
            Logger.warning(msg)
            err
        end
    end
  end

  def maybe_setup(other) do
    Logger.warning(
      "WireGuardNat.maybe_setup: expected interface + tunnel_subnet, got: #{inspect(other)}"
    )

    {:error, :bad_args}
  end

  defp auto_nat_disabled? do
    case Diode.Config.get("WIREGUARD_AUTO_NAT") do
      v when v in ~w(0 false no off) -> true
      _ -> false
    end
  end

  defp setup_linux_iptables(wg_subnet, wg_iface) do
    with {:ok, ipt} <- iptables_executable(),
         {:ok, egress} <- default_egress_device() do
      Logger.info(
        "WireGuardNat: using #{ipt}, subnet=#{wg_subnet}, wg=#{wg_iface}, egress=#{egress}"
      )

      with :ok <-
             ensure_rule(ipt, "nat", "POSTROUTING", [
               "-s",
               wg_subnet,
               "-o",
               egress,
               "-j",
               "MASQUERADE"
             ]),
           :ok <-
             ensure_rule(ipt, "filter", "FORWARD", ["-i", wg_iface, "-o", egress, "-j", "ACCEPT"]),
           :ok <-
             ensure_rule(ipt, "filter", "FORWARD", [
               "-i",
               egress,
               "-o",
               wg_iface,
               "-m",
               "state",
               "--state",
               "RELATED,ESTABLISHED",
               "-j",
               "ACCEPT"
             ]) do
        :ok
      end
    end
  end

  @doc false
  @spec iptables_binary_candidates(:auto | boolean()) :: [String.t()]
  def iptables_binary_candidates(:auto), do: iptables_try_order()

  def iptables_binary_candidates(legacy_dual_stack) when is_boolean(legacy_dual_stack) do
    if legacy_dual_stack,
      do: @iptables_try_legacy_first,
      else: @iptables_try_default_first
  end

  defp iptables_try_order do
    if legacy_tables_alongside_nft?(),
      do: @iptables_try_legacy_first,
      else: @iptables_try_default_first
  end

  defp legacy_tables_alongside_nft? do
    case System.find_executable("iptables-nft") do
      nil ->
        false

      exe ->
        case System.cmd(exe, ["-t", "filter", "-S"], stderr_to_stdout: true) do
          {out, _} -> String.contains?(out, "iptables-legacy tables present")
        end
    end
  end

  defp iptables_executable do
    names = iptables_try_order()

    case Enum.find_value(names, &System.find_executable/1) do
      nil -> {:error, {:iptables_not_found, names}}
      path -> {:ok, path}
    end
  end

  def default_egress_device do
    case System.cmd("ip", ["route", "show", "default", "0.0.0.0/0"], stderr_to_stdout: true) do
      {out, 0} ->
        default_egress_from_ip_route_output(out)

      {err, st} ->
        {:error, {:ip_route, st, err}}
    end
  end

  @doc """
  Parses the first line of `ip route show default` output to extract the egress interface name.
  Used by tests and [default_egress_device/0].
  """
  def default_egress_from_ip_route_output(out) when is_binary(out) do
    line = out |> String.split("\n", trim: true) |> List.first() || ""

    case Regex.run(~r/\bdev\s+(\S+)/, line) do
      [_, dev] -> {:ok, dev}
      _ -> {:error, {:no_default_route, String.trim(out)}}
    end
  end

  defp ensure_rule(ipt, table, chain, args) do
    check = [ipt, "-t", table, "-C", chain] ++ args

    case System.cmd(hd(check), tl(check), stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      _ ->
        add = [ipt, "-t", table, "-A", chain] ++ args

        case System.cmd(hd(add), tl(add), stderr_to_stdout: true) do
          {_, 0} -> :ok
          {out, code} -> {:error, {:iptables, Enum.join(add, " "), code, String.trim(out)}}
        end
    end
  end

  defp format_nat_warning({:error, {:iptables_not_found, names}}) do
    {"WireGuardNat: iptables not found (tried #{inspect(names)}). Install iptables or run sudo scripts/setup-wg-nat.sh.",
     :iptables_not_found}
  end

  defp format_nat_warning({:error, {:ip_route, st, err}}) do
    {"WireGuardNat: could not detect default route (exit #{st}): #{err}. Set a default gateway or run sudo scripts/setup-wg-nat.sh.",
     :ip_route}
  end

  defp format_nat_warning({:error, {:no_default_route, out}}) do
    {"WireGuardNat: no default route in `ip route` output: #{inspect(out)}. Run sudo scripts/setup-wg-nat.sh with EGRESS_DEV=...",
     :no_default_route}
  end

  defp format_nat_warning({:error, {:iptables, cmd, code, out}}) do
    {"WireGuardNat: iptables failed (#{code}): #{cmd}\n#{out}\nRun as root or: sudo scripts/setup-wg-nat.sh",
     :iptables}
  end
end
