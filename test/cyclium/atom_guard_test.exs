defmodule Cyclium.AtomGuardTest do
  use ExUnit.Case, async: false

  alias Cyclium.AtomGuard

  setup do
    on_exit(fn -> Application.delete_env(:cyclium, :atom_guard_max_usage) end)
    :ok
  end

  describe "intern!/1" do
    test "passes atoms through unchanged" do
      assert AtomGuard.intern!(:already_an_atom) == :already_an_atom
      assert AtomGuard.intern!(nil) == nil
    end

    test "reuses an existing atom without minting" do
      # :existing_atom_guard_fixture is created here at compile/first-eval time
      existing = :existing_atom_guard_fixture
      before = :erlang.system_info(:atom_count)

      assert AtomGuard.intern!("existing_atom_guard_fixture") == existing
      # No growth: the atom already existed
      assert :erlang.system_info(:atom_count) == before
    end

    test "mints a genuinely new atom when there is headroom" do
      unique = "atom_guard_new_#{System.unique_integer([:positive])}"
      atom = AtomGuard.intern!(unique)
      assert is_atom(atom)
      assert to_string(atom) == unique
    end

    test "stringifies non-binary, non-atom input" do
      assert AtomGuard.intern!(123) == :"123"
    end

    test "raises LimitError when the atom table is over the threshold (new atoms only)" do
      # Threshold 0.0 => any *new* mint is refused.
      Application.put_env(:cyclium, :atom_guard_max_usage, 0.0)

      assert_raise AtomGuard.LimitError, fn ->
        AtomGuard.intern!("atom_guard_should_not_exist_#{System.unique_integer([:positive])}")
      end
    end

    test "still returns existing atoms even when over the threshold" do
      # Reloads of known definitions must keep working under atom pressure.
      _ = :atom_guard_existing_under_pressure
      Application.put_env(:cyclium, :atom_guard_max_usage, 0.0)

      assert AtomGuard.intern!("atom_guard_existing_under_pressure") ==
               :atom_guard_existing_under_pressure
    end
  end

  describe "existing_atom/1" do
    test "returns {:ok, atom} for an existing atom" do
      _ = :atom_guard_existing_check

      assert {:ok, :atom_guard_existing_check} =
               AtomGuard.existing_atom("atom_guard_existing_check")
    end

    test "returns :error for an unknown string and never mints" do
      unique = "atom_guard_never_minted_#{System.unique_integer([:positive])}"
      before = :erlang.system_info(:atom_count)

      assert :error = AtomGuard.existing_atom(unique)
      assert :erlang.system_info(:atom_count) == before
    end
  end

  describe "Jason integration (keys: &intern!/1)" do
    test "atomizes JSON keys through the guard" do
      assert %{atom_guard_json_key: 1} =
               Jason.decode!(~s({"atom_guard_json_key": 1}), keys: &AtomGuard.intern!/1)
    end

    test "refuses to atomize a brand-new key when over threshold" do
      Application.put_env(:cyclium, :atom_guard_max_usage, 0.0)
      unique = "atom_guard_json_new_#{System.unique_integer([:positive])}"

      assert_raise AtomGuard.LimitError, fn ->
        Jason.decode!(~s({"#{unique}": 1}), keys: &AtomGuard.intern!/1)
      end
    end
  end
end
