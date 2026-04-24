defmodule Cyclium.MixProject do
  use Mix.Project

  def project do
    [
      app: :cyclium,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [
        plt_add_apps: [:ecto, :ecto_sql, :phoenix_pubsub],
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
      ],
      name: "Cyclium",
      description: description(),
      package: package()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ecto, "~> 3.10"},
      {:ecto_sql, "~> 3.10"},
      {:jason, "~> 1.2"},
      {:phoenix_pubsub, "~> 2.1"},
      {:ecto_sqlite3, ">= 0.0.0", only: :test},
      {:stream_data, "~> 1.0"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    """
    Cyclium is a framework for building and orchestrating long-running, stateful processes ("actors") in Elixir.
    """
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{}
    ]
  end
end
