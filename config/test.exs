import Config

config :cyclium, Cyclium.Test.Repo,
  database: "file:cyclium_test?mode=memory&cache=shared",
  pool: Ecto.Adapters.SQL.Sandbox

config :cyclium,
  repo: Cyclium.Test.Repo,
  ecto_repos: [Cyclium.Test.Repo]
