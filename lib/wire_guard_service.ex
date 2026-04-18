# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule WireGuardService do
  use GenServer
  require Logger
  alias DiodeClient.Base16
  import Wireguardex.DeviceConfigBuilder
  import Wireguardex.PeerConfigBuilder, only: [allowed_ips: 2]
  import Wireguardex, only: [delete_device: 1, set_device: 2]

  def start_link(_args) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def add_peer(device_address, public_key_binary)
      when is_binary(device_address) and is_binary(public_key_binary) do
    GenServer.call(__MODULE__, {:add_peer, device_address, public_key_binary})
  end

  @doc """
  Builds the WireGuardSessionInfo map (spec v0.1.4) for RPC and Edge responses.
  All map keys are UTF-8 strings; `listen_port` is a non-negative integer.
  """
  def session_info_map(server_public_key, endpoint_host, listen_port, client_address)
      when is_binary(server_public_key) and is_binary(endpoint_host) and is_integer(listen_port) and
             listen_port >= 0 and is_binary(client_address) do
    %{
      "server_public_key" => server_public_key,
      "endpoint_host" => endpoint_host,
      "listen_port" => listen_port,
      "client_address" => client_address
    }
  end

  def remove_peer(device_address) when is_binary(device_address) do
    GenServer.call(__MODULE__, {:remove_peer, device_address})
  end

  def init(_args) do
    enabled = wireguard_enabled?()
    interface = Diode.Config.get("WIREGUARD_INTERFACE")
    listen_port = Diode.Config.get_int("WIREGUARD_LISTEN_PORT")
    tunnel_subnet = Diode.Config.get("WIREGUARD_TUNNEL_SUBNET")
    poll_interval_ms = Diode.Config.get_int("WIREGUARD_POLL_INTERVAL_MS")
    gateway_cidr = Diode.Config.get("WIREGUARD_GATEWAY_CIDR")

    state = %{
      enabled: enabled,
      interface: interface,
      listen_port: listen_port,
      tunnel_subnet: tunnel_subnet,
      gateway_cidr: gateway_cidr,
      poll_interval_ms: poll_interval_ms,
      private_key: nil,
      kernel_ready: false,
      peers: %{},
      traffic_snapshots: %{},
      poll_timer: nil
    }

    if enabled and listen_port > 0 do
      case setup_interface(state) do
        {:ok, new_state} ->
          host = endpoint_host_for_session()

          Logger.info(
            "WireGuard endpoint for sessions: host=#{inspect(host)}, listen_port=#{listen_port}, interface=#{interface}"
          )

          {:ok, new_state}

        {:error, reason} ->
          Logger.error("Failed to start WireGuard interface: #{inspect(reason)}")
          {:ok, state}
      end
    else
      Logger.info("WireGuard disabled or listen_port not configured")
      {:ok, state}
    end
  end

  def handle_call({:add_peer, device_address, public_key_binary}, _from, state) do
    cond do
      not state.enabled or state.listen_port == 0 ->
        {:reply, {:error, :not_enabled}, state}

      not state.kernel_ready ->
        {:reply,
         {:error,
          {:wireguard,
           "kernel link/address setup did not complete (interface DOWN or no IP). " <>
             "Check earlier WireGuardKernel error in the node log."}}, state}

      true ->
        case add_peer_impl(device_address, public_key_binary, state) do
          {:ok, new_state} ->
            case session_info_after_add(device_address, new_state) do
              {:ok, session} ->
                {:reply, {:ok, session}, new_state}

              {:error, reason} ->
                {:reply, {:error, {:wireguard, reason}}, new_state}
            end

          {:error, _reason} = error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:remove_peer, device_address}, _from, state) do
    if not state.enabled do
      {:reply, :ok, state}
    else
      new_state = remove_peer_impl(device_address, state)
      {:reply, :ok, new_state}
    end
  end

  def handle_info(:poll_traffic, state) do
    if state.enabled and state.listen_port > 0 do
      new_state = poll_traffic_impl(state)
      timer = Process.send_after(self(), :poll_traffic, state.poll_interval_ms)
      {:noreply, %{new_state | poll_timer: timer}}
    else
      {:noreply, state}
    end
  end

  defp setup_interface(state) do
    try do
      # If a kernel interface survived a previous BEAM run, we must remove it or
      # re-apply config — never short-circuit with :already_started or the new
      # process loses its private_key while RPC still reads a stale public_key.
      case Wireguardex.get_device(state.interface) do
        {:ok, _} ->
          case delete_device(state.interface) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.error(
                "WireGuard could not delete stale interface #{state.interface}: #{inspect(reason)}"
              )

              {:error, {:wireguard, reason}}
          end

        {:error, _} ->
          :ok
      end
      |> case do
        {:error, _} = err ->
          err

        :ok ->
          private_key = Wireguardex.generate_private_key()
          public_key_result = Wireguardex.get_public_key(private_key)

          case public_key_result do
            {:ok, _public_key} ->
              device_config =
                device_config()
                |> private_key(private_key)
                |> listen_port(state.listen_port)

              case set_device(device_config, state.interface) do
                :ok ->
                  Logger.info(
                    "WireGuard interface #{state.interface} configured on port #{state.listen_port}"
                  )

                  kernel_ready =
                    case WireGuardKernel.setup_link(state.interface, state.gateway_cidr) do
                      :ok ->
                        _ =
                          WireGuardNat.maybe_setup(%{
                            interface: state.interface,
                            tunnel_subnet: state.tunnel_subnet
                          })

                        true

                      {:error, reason} ->
                        # Don't fail GenServer init: surface the precise reason as a fail-soft.
                        # add_peer_impl/3 will return a clear error to clients while we're degraded.
                        Logger.error(
                          "WireGuard kernel bring-up failed for #{state.interface} " <>
                            "(gateway=#{inspect(state.gateway_cidr)}): #{inspect(reason)}. " <>
                            "Verify BEAM has CAP_NET_ADMIN (`getcap $(readlink -f $(asdf where erlang)/erts-*/bin/beam.smp)`)."
                        )

                        false
                    end

                  timer = Process.send_after(self(), :poll_traffic, state.poll_interval_ms)

                  new_state = %{
                    state
                    | private_key: private_key,
                      kernel_ready: kernel_ready,
                      poll_timer: timer
                  }

                  {:ok, new_state}

                {:error, reason} ->
                  {:error, {:wireguard, reason}}
              end

            {:error, reason} ->
              {:error, {:wireguard, reason}}
          end
      end
    rescue
      e ->
        Logger.error("WireGuard setup error: #{inspect(e)}")
        {:error, {:wireguard, Exception.message(e)}}
    catch
      :exit, reason ->
        Logger.error("WireGuard setup exit: #{inspect(reason)}")
        {:error, {:wireguard, inspect(reason)}}
    end
  end

  defp add_peer_impl(device_address, public_key_binary, state) do
    # Validate public key is 32 bytes
    if byte_size(public_key_binary) != 32 do
      {:error, :invalid_public_key}
    else
      # Convert to Base64 for wireguardex
      public_key_base64 = Base.encode64(public_key_binary)

      # Check if device already has a peer
      old_peer = Map.get(state.peers, device_address)

      state =
        if old_peer != nil do
          # Remove old peer and account traffic
          account_and_remove_peer(device_address, old_peer, state)
        else
          state
        end

      # Assign tunnel IP from subnet
      tunnel_ip = assign_tunnel_ip(device_address, state.tunnel_subnet, state.peers)

      # Build peer config with allowed_ips = tunnel_ip/32 only
      peer_config =
        Wireguardex.PeerConfigBuilder.peer_config()
        |> Wireguardex.PeerConfigBuilder.public_key(public_key_base64)
        |> allowed_ips([tunnel_ip])

      # Add peer to WireGuard
      case Wireguardex.add_peer(state.interface, peer_config) do
        :ok ->
          # Update state
          new_peers = Map.put(state.peers, device_address, {public_key_base64, tunnel_ip})
          new_snapshots = Map.put(state.traffic_snapshots, device_address, {0, 0})

          Logger.info(
            "Added WireGuard peer for device #{Base16.encode(device_address, false)} with IP #{tunnel_ip}"
          )

          {:ok, %{state | peers: new_peers, traffic_snapshots: new_snapshots}}

        {:error, reason} ->
          {:error, {:wireguard, reason}}
      end
    end
  end

  defp remove_peer_impl(device_address, state) do
    peer = Map.get(state.peers, device_address)

    if peer != nil do
      account_and_remove_peer(device_address, peer, state)
    else
      state
    end
  end

  defp account_and_remove_peer(device_address, {public_key_base64, _tunnel_ip}, state) do
    # Account traffic before removal
    state = account_traffic_for_peer(device_address, state)

    # Remove from WireGuard
    case Wireguardex.remove_peer(state.interface, public_key_base64) do
      :ok ->
        Logger.info("Removed WireGuard peer for device #{Base16.encode(device_address, false)}")

      {:error, reason} ->
        Logger.warning("Error removing WireGuard peer: #{inspect(reason)}")
    end

    # Update state
    new_peers = Map.delete(state.peers, device_address)
    new_snapshots = Map.delete(state.traffic_snapshots, device_address)

    %{state | peers: new_peers, traffic_snapshots: new_snapshots}
  end

  defp poll_traffic_impl(state) do
    state = verify_kernel_public_key_matches_state(state)

    case Wireguardex.get_device(state.interface) do
      {:ok, device} ->
        # Get peers from device (device.peers is a list of PeerInfo structs)
        peers = device.peers

        # For each peer in our state, find matching peer in device and compute delta
        Enum.reduce(state.peers, state, fn {device_address, {public_key_base64, _tunnel_ip}},
                                           acc ->
          # Find peer in device by public key (PeerInfo has config and stats)
          device_peer_info =
            Enum.find(peers, fn peer_info ->
              peer_info.config.public_key == public_key_base64
            end)

          if device_peer_info != nil do
            # Get stats from PeerInfo struct
            stats = device_peer_info.stats
            rx_bytes = stats.rx_bytes
            tx_bytes = stats.tx_bytes
            total_bytes = rx_bytes + tx_bytes

            # Get last snapshot
            {last_rx, last_tx} = Map.get(acc.traffic_snapshots, device_address, {0, 0})
            last_total = last_rx + last_tx

            # Compute delta
            delta = total_bytes - last_total

            if delta > 0 do
              TicketStore.increase_device_usage(device_address, delta)
            end

            # Update snapshot
            new_snapshots = Map.put(acc.traffic_snapshots, device_address, {rx_bytes, tx_bytes})
            %{acc | traffic_snapshots: new_snapshots}
          else
            acc
          end
        end)

      {:error, reason} ->
        Logger.warning("Error polling WireGuard traffic: #{inspect(reason)}")
        state
    end
  end

  defp verify_kernel_public_key_matches_state(state) do
    if state.private_key in [nil, ""] do
      state
    else
      expected =
        case Wireguardex.get_public_key(state.private_key) do
          {:ok, pk} -> pk
          _ -> nil
        end

      if expected == nil do
        state
      else
        case Wireguardex.get_device(state.interface) do
          {:ok, %Wireguardex.Device{public_key: actual}}
          when is_binary(actual) and actual != "" and actual != expected ->
            Logger.error(
              "WireGuard kernel public_key no longer matches BEAM private_key for #{state.interface}. " <>
                "Restart the node or fix CAP_NET_ADMIN / snap network-control."
            )

            state

          _ ->
            state
        end
      end
    end
  end

  defp account_traffic_for_peer(device_address, state) do
    case Wireguardex.get_device(state.interface) do
      {:ok, device} ->
        peers = device.peers
        {public_key_base64, _tunnel_ip} = Map.get(state.peers, device_address)

        device_peer_info =
          Enum.find(peers, fn peer_info ->
            peer_info.config.public_key == public_key_base64
          end)

        if device_peer_info != nil do
          stats = device_peer_info.stats
          rx_bytes = stats.rx_bytes
          tx_bytes = stats.tx_bytes
          total_bytes = rx_bytes + tx_bytes

          {last_rx, last_tx} = Map.get(state.traffic_snapshots, device_address, {0, 0})
          last_total = last_rx + last_tx
          delta = total_bytes - last_total

          if delta > 0 do
            TicketStore.increase_device_usage(device_address, delta)
          end
        end

        state

      {:error, _reason} ->
        state
    end
  end

  defp assign_tunnel_ip(_device_address, subnet, existing_peers) do
    # Parse subnet (e.g., "10.0.0.0/24")
    [base_ip_str, prefix_len_str] = String.split(subnet, "/")
    prefix_len = String.to_integer(prefix_len_str)

    # Get base IP as integer
    [a, b, c, d] = String.split(base_ip_str, ".") |> Enum.map(&String.to_integer/1)
    base_ip = :erlang.list_to_tuple([a, b, c, d])

    # Get used IPs
    used_ips =
      existing_peers
      |> Map.values()
      |> Enum.map(fn {_key, ip_str} -> ip_str end)
      |> Enum.map(fn ip_str ->
        [a, b, c, d] =
          String.split(ip_str, "/") |> hd() |> String.split(".") |> Enum.map(&String.to_integer/1)

        :erlang.list_to_tuple([a, b, c, d])
      end)
      |> MapSet.new()

    # Find next available IP in subnet
    # For /24, we can use .2 to .254 (skip .0, .1, .255)
    start_ip =
      case base_ip do
        {a, b, c, _d} -> {a, b, c, 2}
      end

    ip = find_next_available_ip(start_ip, used_ips, prefix_len)

    # Format as "a.b.c.d/32"
    {a, b, c, d} = ip
    "#{a}.#{b}.#{c}.#{d}/32"
  end

  defp find_next_available_ip(ip, used_ips, prefix_len) do
    if MapSet.member?(used_ips, ip) do
      {a, b, c, d} = ip
      next_d = if d < 254, do: d + 1, else: 2
      next_ip = {a, b, c, next_d}
      find_next_available_ip(next_ip, used_ips, prefix_len)
    else
      ip
    end
  end

  defp session_info_after_add(device_address, new_state) do
    {_pub64, client_cidr} = Map.fetch!(new_state.peers, device_address)

    with {:ok, server_pk} <- server_public_key_from_state(new_state) do
      host = endpoint_host_for_session()

      {:ok, session_info_map(server_pk, host, new_state.listen_port, client_cidr)}
    end
  end

  defp server_public_key_from_state(state) do
    cond do
      is_binary(state.private_key) and state.private_key != "" ->
        Wireguardex.get_public_key(state.private_key)

      true ->
        case Wireguardex.get_device(state.interface) do
          {:ok, %Wireguardex.Device{public_key: pk}}
          when is_binary(pk) and pk != "" ->
            {:ok, pk}

          {:ok, _} ->
            {:error, "no server public key on device"}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp endpoint_host_for_session do
    case Diode.Config.get("WIREGUARD_ENDPOINT_HOST") do
      host when is_binary(host) and host != "" ->
        host

      _ ->
        Diode.Config.get("HOST") || ""
    end
  end

  defp wireguard_enabled? do
    enabled = Diode.Config.get("WIREGUARD_ENABLED")
    enabled in ~w(1 true)
  end
end
