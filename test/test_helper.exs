ExUnit.start()

# Boot the SQLite in-memory test repo.
# Uses a shared-cache URI so all pool connections see the same database.
# Migration must run before sandbox mode is set to :manual.
{:ok, _} = Cyclium.Test.Repo.start_link()
Ecto.Migrator.run(Cyclium.Test.Repo, [{1, Cyclium.Test.Migration}], :up, all: true)
Ecto.Adapters.SQL.Sandbox.mode(Cyclium.Test.Repo, :manual)
