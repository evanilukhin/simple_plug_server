defmodule SimplePlugServer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      Plug.Cowboy.child_spec(
        scheme: :http,
        plug: SimplePlugServer.Endpoint,
        options: [port: String.to_integer(Application.get_env(:simple_plug_server, :port))]
      )
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SimplePlugServer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
