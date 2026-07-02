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
    refute String.contains?(body, ~s(Example request</p>\n        <pre></pre>))
  end

  test "RpcDocs notification examples are encoded strings without example_request" do
    for slug <- ["dio_ticket_request", "dio_notify"] do
      doc = Enum.find(Network.RpcDocs.all(), &(&1.slug == slug))

      refute Map.has_key?(doc, :example_request)
      assert is_binary(doc.example_response)
      assert String.starts_with?(doc.example_response, "{")
    end
  end
end
