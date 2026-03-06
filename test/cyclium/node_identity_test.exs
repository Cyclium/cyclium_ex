defmodule Cyclium.NodeIdentityTest do
  use ExUnit.Case, async: false

  setup do
    # Clean up any config overrides
    original = Application.get_env(:cyclium, :node_identity)

    on_exit(fn ->
      if original do
        Application.put_env(:cyclium, :node_identity, original)
      else
        Application.delete_env(:cyclium, :node_identity)
      end

      :persistent_term.erase(:cyclium_node_identity)
    end)

    :ok
  end

  test "returns node name by default when distributed" do
    Application.delete_env(:cyclium, :node_identity)
    # In test environment node() is :nonode@nohost, so it generates a stable identity
    name = Cyclium.NodeIdentity.name()
    assert is_binary(name)
    assert String.starts_with?(name, "nonode-")
  end

  test "returns stable identity across calls" do
    Application.delete_env(:cyclium, :node_identity)
    name1 = Cyclium.NodeIdentity.name()
    name2 = Cyclium.NodeIdentity.name()
    assert name1 == name2
  end

  test "returns static override from config" do
    Application.put_env(:cyclium, :node_identity, "my-custom-node")
    assert Cyclium.NodeIdentity.name() == "my-custom-node"
  end

  test "returns MFA callback result" do
    Application.put_env(:cyclium, :node_identity, {String, :upcase, ["test-node"]})
    assert Cyclium.NodeIdentity.name() == "TEST-NODE"
  end

  test "converts atom config to string" do
    Application.put_env(:cyclium, :node_identity, :my_node)
    assert Cyclium.NodeIdentity.name() == "my_node"
  end
end
