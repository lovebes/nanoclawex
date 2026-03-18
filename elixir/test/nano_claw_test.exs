defmodule NanoClawTest do
  use ExUnit.Case

  doctest NanoClaw

  test "greets the world" do
    assert NanoClaw.hello() == :world
  end
end
