# Diode Server
# Copyright 2021-2026 Diode
# Licensed under the Diode License, Version 1.1
defmodule ConnectivityTest do
  @moduledoc """
  Regression tests for `Connectivity.check_connectivity/0..1`.

  Covers the HTTP call sites formerly backed by HTTPoison (now Req):
  success decoding, HOST config update, port query construction,
  non-200 responses, and transport failures.
  """
  use ExUnit.Case, async: false

  # Stand-in for https://monitor.testnet.diode.io
  defmodule MonitorPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      if test_pid = opts[:test_pid] do
        send(test_pid, {:monitor_request, conn.request_path, conn.query_string})
      end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(opts[:status] || 200, opts[:body] || "")
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:plug_cowboy)
    {:ok, _} = Application.ensure_all_started(:req)

    old_host_globals = Globals.get({Diode.Config, "HOST"})
    old_host_env = System.get_env("HOST")

    on_exit(fn ->
      Application.delete_env(:diode, :monitor_url)

      # Undo Diode.Config.set("HOST", ...) side effects
      Globals.pop({Diode.Config, "HOST"})

      if old_host_globals != nil do
        Globals.put({Diode.Config, "HOST"}, old_host_globals)
      end

      case old_host_env do
        nil -> System.delete_env("HOST")
        value -> System.put_env("HOST", value)
      end

      # set("HOST", ...) schedules peer/turn restarts via Debouncer
      Debouncer.cancel({Diode.Config, :restart_peer_handler})
      Debouncer.cancel({Diode.Config, :restart_turn_service})
    end)

    :ok
  end

  test "returns the monitor payload and updates HOST" do
    body = Poison.encode!(%{"ip" => "203.0.113.7", "ports" => [41046]})

    with_monitor([status: 200, body: body, test_pid: self()], fn ->
      assert %{"ip" => "203.0.113.7", "ports" => [41046]} = Connectivity.check_connectivity()
      assert Diode.Config.get("HOST") == "203.0.113.7"
      assert_received {:monitor_request, "/ip/self", ""}
    end)
  end

  test "check_connectivity(:all) reports peer and edge ports in the query" do
    body = Poison.encode!(%{"ip" => "203.0.113.7", "ports" => []})

    with_monitor([status: 200, body: body, test_pid: self()], fn ->
      assert %{"ip" => "203.0.113.7"} = Connectivity.check_connectivity(:all)

      expected =
        [Diode.peer2_port() | Diode.edge2_ports()]
        |> Enum.join(",")
        |> then(&"ports=#{&1}")

      assert_received {:monitor_request, "/ip/self", ^expected}
    end)
  end

  test "non-200 monitor responses return an error tuple instead of crashing" do
    with_monitor([status: 503, body: "unavailable"], fn ->
      assert {:error, {:http_status, 503}} = Connectivity.check_connectivity()
    end)
  end

  test "unreachable monitor surfaces as error tuple" do
    Application.put_env(:diode, :monitor_url, "http://127.0.0.1:1")
    assert {:error, _reason} = Connectivity.check_connectivity()
  end

  defp with_monitor(opts, fun) do
    ref = {__MODULE__, :monitor}
    {:ok, _pid} = Plug.Cowboy.http(MonitorPlug, opts, port: 0, ref: ref)

    Application.put_env(:diode, :monitor_url, "http://127.0.0.1:#{:ranch.get_port(ref)}")

    try do
      fun.()
    after
      Plug.Cowboy.shutdown(ref)
    end
  end
end
