defmodule Cyclium.UUIDTest do
  use ExUnit.Case, async: false

  defmodule OwnCodecAdapter do
    def loaders(:binary_id, type), do: [__MODULE__.Codec, type]

    defmodule Codec do
      def dump(_uuid), do: {:ok, <<1::128>>}
      def load(<<1::128>>), do: {:ok, "00000000-0000-0000-0000-000000000001"}
    end
  end

  defmodule RepoOn do
    def __adapter__, do: Application.get_env(:cyclium, :uuid_test_adapter)
  end

  setup do
    original = Application.get_env(:cyclium, :repo)
    Application.put_env(:cyclium, :repo, RepoOn)

    on_exit(fn ->
      Application.delete_env(:cyclium, :uuid_test_adapter)

      if original,
        do: Application.put_env(:cyclium, :repo, original),
        else: Application.delete_env(:cyclium, :repo)
    end)
  end

  defp on_adapter(adapter), do: Application.put_env(:cyclium, :uuid_test_adapter, adapter)

  test "reports :uuid, so a primary key is generated here and dumped" do
    assert Cyclium.UUID.type() == :uuid
    assert {:ok, _} = Ecto.UUID.cast(Cyclium.UUID.autogenerate())

    assert Cyclium.Schemas.Finding.__schema__(:autogenerate) == [
             {[:id], {Cyclium.UUID, :autogenerate, []}}
           ]

    assert Cyclium.Schemas.Finding.__schema__(:autogenerate_id) == nil
  end

  test "dumps and loads through the adapter's own :binary_id codec" do
    on_adapter(OwnCodecAdapter)
    uuid = Ecto.UUID.generate()

    assert Cyclium.UUID.dump(uuid) == {:ok, <<1::128>>}
    assert Cyclium.UUID.load(<<1::128>>) == {:ok, "00000000-0000-0000-0000-000000000001"}
  end

  test "an adapter that loads :binary_id as is, or no adapter, gets Ecto.UUID's bytes" do
    uuid = Ecto.UUID.generate()

    on_adapter(Ecto.Adapters.SQLite3)
    assert Cyclium.UUID.dump(uuid) == Ecto.UUID.dump(uuid)

    Application.put_env(:cyclium, :repo, Cyclium.FakeRepo)
    assert Cyclium.UUID.dump(uuid) == Ecto.UUID.dump(uuid)
    assert Cyclium.UUID.load(elem(Ecto.UUID.dump(uuid), 1)) == {:ok, uuid}
  end

  test "a string loads cast, and a value that is no UUID neither casts nor dumps" do
    uuid = Ecto.UUID.generate()

    assert Cyclium.UUID.load(String.upcase(uuid)) == {:ok, uuid}
    assert Cyclium.UUID.cast("not-a-uuid") == :error
    assert Cyclium.UUID.dump("not-a-uuid") == :error
  end
end
