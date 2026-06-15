defmodule Cyclium.Exports do
  @moduledoc """
  Durable, downloadable artifacts an actor produces for a principal (e.g. a
  CSV). An export is a blob persisted to `cyclium_exports`, fetched on demand
  via a signed, expiring link — scoped to the principal that requested it.

  This is the framework half; a web app mounts a small controller that verifies
  the token (`valid_token?/2`), loads the export (`fetch_valid/1`), checks the
  caller owns it, and streams the content. Any actor in any app can create
  exports (see `Cyclium.Tools.CsvExport`).

  ## Configuration

      config :cyclium, :export_signing_secret, "<a long random secret>"
      config :cyclium, :export_ttl_seconds, 604_800  # optional, default 7 days

  The token is an HMAC of the export id (no external signing dep); the TTL is
  enforced server-side via `expires_at`, so the token itself carries no expiry.
  """

  import Ecto.Query

  alias Cyclium.Schemas.Export

  @default_ttl_seconds 7 * 24 * 60 * 60

  @doc """
  Create an export. Required: `:principal_type`, `:principal_id`, `:filename`,
  `:content`. Optional: `:type` (default "csv"), `:content_type`,
  `:episode_id`, `:conversation_id`, `:ttl_seconds`. Stamps `created_at`,
  `expires_at`, and `byte_size`.
  """
  @spec create(map()) :: {:ok, Export.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) when is_map(attrs) do
    attrs = normalize(attrs)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    ttl = Map.get(attrs, :ttl_seconds, ttl_seconds())
    content = attrs[:content] || ""

    %Export{}
    |> Export.changeset(
      attrs
      |> Map.drop([:ttl_seconds])
      |> Map.merge(%{
        created_at: now,
        expires_at: DateTime.add(now, ttl, :second),
        byte_size: byte_size(content)
      })
    )
    |> Cyclium.repo().insert()
  end

  @doc "Fetch an export by id only if it exists and has not expired."
  @spec fetch_valid(binary()) :: Export.t() | nil
  def fetch_valid(id) when is_binary(id) do
    case Cyclium.repo().get(Export, id) do
      nil -> nil
      %Export{} = export -> if expired?(export), do: nil, else: export
    end
  rescue
    # An invalid binary_id (bad URL) shouldn't 500.
    Ecto.Query.CastError -> nil
  end

  @doc "Delete all expired exports. Returns the number deleted. Schedule periodically."
  @spec purge_expired() :: non_neg_integer()
  def purge_expired do
    now = DateTime.utc_now()

    {count, _} =
      from(e in Export, where: not is_nil(e.expires_at) and e.expires_at < ^now)
      |> Cyclium.repo().delete_all()

    count
  end

  @doc "An opaque HMAC token binding a download link to one export id."
  @spec sign(binary()) :: binary()
  def sign(id) when is_binary(id) do
    Base.url_encode64(mac(id), padding: false)
  end

  @doc "Constant-time check that `token` was issued by `sign/1` for `id`."
  @spec valid_token?(binary(), binary()) :: boolean()
  def valid_token?(id, token) when is_binary(id) and is_binary(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, got} -> secure_equal?(got, mac(id))
      :error -> false
    end
  end

  def valid_token?(_id, _token), do: false

  # --- internal ---

  defp expired?(%Export{expires_at: nil}), do: false
  defp expired?(%Export{expires_at: at}), do: DateTime.compare(at, DateTime.utc_now()) != :gt

  defp mac(id), do: :crypto.mac(:hmac, :sha256, signing_secret(), id)

  defp secure_equal?(a, b) when byte_size(a) == byte_size(b) do
    a
    |> :crypto.exor(b)
    |> :binary.bin_to_list()
    |> Enum.reduce(0, &Bitwise.bor/2)
    |> Kernel.==(0)
  end

  defp secure_equal?(_a, _b), do: false

  defp signing_secret do
    Application.get_env(:cyclium, :export_signing_secret) ||
      raise "Cyclium.Exports requires config :cyclium, :export_signing_secret"
  end

  defp ttl_seconds, do: Application.get_env(:cyclium, :export_ttl_seconds, @default_ttl_seconds)

  # Accept string or atom keys; keep the canonical atom set the changeset expects.
  defp normalize(attrs) do
    Map.new(attrs, fn {k, v} -> {to_atom(k), v} end)
  end

  defp to_atom(k) when is_atom(k), do: k
  defp to_atom(k) when is_binary(k), do: String.to_existing_atom(k)
end
