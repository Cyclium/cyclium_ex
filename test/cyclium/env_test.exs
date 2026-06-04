defmodule Cyclium.EnvTest do
  use ExUnit.Case, async: false

  alias Cyclium.Env

  setup do
    on_exit(fn -> Application.delete_env(:cyclium, :env) end)
    :ok
  end

  describe "current/0" do
    test "nil when unset" do
      Application.delete_env(:cyclium, :env)
      assert Env.current() == nil
    end

    test "nil when blank" do
      Application.put_env(:cyclium, :env, "")
      assert Env.current() == nil
    end

    test "stringifies the configured value" do
      Application.put_env(:cyclium, :env, :dev_jane)
      assert Env.current() == "dev_jane"
    end
  end

  describe "scope_key/1" do
    test "returns the key unchanged when env is unset (byte-identical)" do
      Application.delete_env(:cyclium, :env)
      assert Env.scope_key("event:actor:exp:123") == "event:actor:exp:123"
    end

    test "suffixes the env when set" do
      Application.put_env(:cyclium, :env, "dev-jane")
      assert Env.scope_key("event:actor:exp:123") == "event:actor:exp:123:dev-jane"
    end

    test "two envs produce distinct keys; same env is stable" do
      Application.put_env(:cyclium, :env, "dev-jane")
      a = Env.scope_key("k")
      a2 = Env.scope_key("k")

      Application.put_env(:cyclium, :env, "prod")
      b = Env.scope_key("k")

      assert a == a2
      assert a != b
    end

    test "nil key stays nil" do
      Application.put_env(:cyclium, :env, "dev-jane")
      assert Env.scope_key(nil) == nil
    end
  end
end
