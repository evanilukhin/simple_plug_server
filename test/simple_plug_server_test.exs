defmodule SimplePlugServerTest do
  use ExUnit.Case
  doctest SimplePlugServer

  test "greets the world" do
    assert SimplePlugServer.hello() == :world
  end
end
