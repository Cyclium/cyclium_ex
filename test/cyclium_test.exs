defmodule CycliumTest do
  use ExUnit.Case

  test "repo/0 raises when not configured" do
    # Temporarily clear the config to test the guard
    original = Application.get_env(:cyclium, :repo)
    Application.delete_env(:cyclium, :repo)

    assert_raise ArgumentError, fn ->
      Cyclium.repo()
    end

    # Restore if it was set
    if original, do: Application.put_env(:cyclium, :repo, original)
  end

  test "repo/0 returns configured repo module" do
    Application.put_env(:cyclium, :repo, MyFakeRepo)

    assert Cyclium.repo() == MyFakeRepo

    Application.delete_env(:cyclium, :repo)
  end
end
