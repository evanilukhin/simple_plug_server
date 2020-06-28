defmodule SimplePlugServer.EndpointTest do
  use ExUnit.Case, async: true
  use Plug.Test

  @opts SimplePlugServer.Endpoint.init([])

  test "it returns pong" do
    # Create a test connection
    conn = conn(:get, "/hello")

    # Invoke the plug
    conn = SimplePlugServer.Endpoint.call(conn, @opts)

    # Assert the response and status
    assert conn.state == :sent
    assert conn.status == 200
    assert conn.resp_body == "Hi! You are awesome!"
  end

  test "it returns 404 when no route matches" do
    # Create a test connection
    conn = conn(:get, "/fail")

    # Invoke the plug
    conn = SimplePlugServer.Endpoint.call(conn, @opts)

    # Assert the response
    assert conn.status == 404
  end
end
