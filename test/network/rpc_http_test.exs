# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.RpcHttpTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  @opts Network.RpcHttp.init([])

  test "GET /api renders all API docs including server notifications" do
    conn =
      :get
      |> conn("/api")
      |> Network.RpcHttp.call(@opts)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]

    body = conn.resp_body
    assert String.contains?(body, "dio_ticket_request")
    assert String.contains?(body, "dio_notify")
    assert String.contains?(body, "Example notification")
    assert String.contains?(body, "Example client request")
    refute String.contains?(body, ~s(Example request</p>\n        <pre></pre>))
  end

  test "RpcDocs notification examples include client follow-up requests" do
    ticket_request = Enum.find(Network.RpcDocs.all(), &(&1.slug == "dio_ticket_request"))
    notify = Enum.find(Network.RpcDocs.all(), &(&1.slug == "dio_notify"))

    for doc <- [ticket_request, notify] do
      assert is_binary(doc[:example_request])
      assert String.contains?(doc[:example_request], "\"method\"")
      assert is_binary(doc.example_response)
      assert String.starts_with?(doc.example_response, "{")
      refute String.contains?(doc.example_response, "\"id\"")
    end

    assert String.contains?(ticket_request[:example_request], "dio_ticket")
    assert String.contains?(notify[:example_request], "dio_message")
  end
end
