defmodule Cyclium.RedactionTest do
  use ExUnit.Case, async: true

  alias Cyclium.Redaction

  test "redacts values under credential-like keys, recursively" do
    args = %{
      "api_key" => "sk-live",
      "nested" => %{"client_secret" => "s", "name" => "ok", token: "abc"},
      "list" => [%{"password" => "p"}, "plain"],
      "Authorization" => "Bearer x"
    }

    assert %{
             "api_key" => "[REDACTED]",
             "nested" => %{"client_secret" => "[REDACTED]", "name" => "ok", token: "[REDACTED]"},
             "list" => [%{"password" => "[REDACTED]"}, "plain"],
             "Authorization" => "[REDACTED]"
           } = Redaction.redact_sensitive(args)
  end

  test "leaves ordinary keys, including token counts, alone" do
    usage = %{"input_tokens" => 10, "output_tokens" => 5, "model" => "m"}
    assert Redaction.redact_sensitive(usage) == usage
  end

  test "does not walk into structs" do
    dt = DateTime.utc_now()
    assert Redaction.redact_sensitive(%{"at" => dt}) == %{"at" => dt}
  end

  test "the key pattern is configurable" do
    Application.put_env(:cyclium, :redact_key_pattern, ~r/^ssn$/)
    on_exit(fn -> Application.delete_env(:cyclium, :redact_key_pattern) end)

    assert Redaction.redact_sensitive(%{"ssn" => "1", "password" => "p"}) ==
             %{"ssn" => "[REDACTED]", "password" => "p"}
  end
end
