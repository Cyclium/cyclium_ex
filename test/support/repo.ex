defmodule Cyclium.Test.Repo do
  use Ecto.Repo,
    otp_app: :cyclium,
    adapter: Ecto.Adapters.SQLite3
end
