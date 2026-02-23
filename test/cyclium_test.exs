defmodule CycliumTest do
  use ExUnit.Case
  doctest Cyclium

  test "greets the world" do
    assert Cyclium.hello() == :world
  end
end
