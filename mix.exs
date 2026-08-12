defmodule Cyclium.MixProject do
  use Mix.Project

  @source_url "https://github.com/Cyclium/cyclium_ex"

  def project do
    [
      app: :cyclium,
      version: "0.3.6",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [
        plt_add_apps: [:ecto, :ecto_sql, :phoenix_pubsub],
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
      ],
      name: "Cyclium",
      source_url: @source_url,
      description: description(),
      package: package(),
      docs: docs()
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
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.40.3", only: :dev, runtime: false}
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
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      extras: [
        "README.md",
        "guides/actors_and_strategies.md",
        "guides/findings_and_outputs.md",
        "guides/workflows.md",
        "guides/dynamic_actors.md",
        "guides/observability.md",
        "guides/distributed_ops.md",
        "guides/advanced.md",
        "guides/interactive_actors.md",
        "guides/conversation_ui.md"
      ],
      groups_for_extras: [
        Guides: ~r{guides/.*}
      ]
    ]
  end
end
