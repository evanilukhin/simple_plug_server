defmodule SimplePlugServer.Endpoint do
  @moduledoc false

  use Plug.Router

  # This module is a Plug, that also implements it's own plug pipeline, below:

  # Using Plug.Logger for logging request information
  plug(Plug.Logger)
  # responsible for matching routes
  plug(:match)
  # Using Poison for JSON decoding
  # Note, order of plugs is important, by placing this _after_ the 'match' plug,
  # we will only parse the request AFTER there is a route match.
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  # responsible for dispatching responses
  plug(:dispatch)

  # A simple route to test that the server is up
  # Note, all routes must return a connection as per the Plug spec.
  get "/hello" do
    send_resp(conn, 200, "Hi! You are great!")
  end

  # A catchall route, 'match' will match no matter the request method,
  # so a response is always returned, even if there is no route to match.
  match _ do
    send_resp(conn, 404, "Nothing to see here!")
  end
end
