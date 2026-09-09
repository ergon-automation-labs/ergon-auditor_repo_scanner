defmodule BotArmyAuditorRepoScanner.MixProject do
  use Mix.Project

  def project do
    [
      app: :bot_army_auditor_repo_scanner,
      version: "0.2.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        auditor_repo_scanner_bot: [
          applications: [bot_army_auditor_repo_scanner: :permanent]
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {BotArmyAuditorRepoScanner.Application, []}
    ]
  end

  defp deps do
    [
      {:bot_army_library_core, path: "../../elixir_bots/bot_army_library_core", override: true},
      {:bot_army_library_runtime, path: "../../elixir_bots/bot_army_library_runtime", override: true},
      {:bot_army_library_learning, path: "../../elixir_bots/bot_army_library_learning", override: true},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, "~> 0.17"},
      {:jason, "~> 1.4"},
      {:logger_json, "~> 5.1"},
      {:elixir_uuid, "~> 1.2"},
      {:req, "~> 0.3"},

      # Development/Test
      {:ex_doc, "~> 0.30", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.0", only: :test},
      {:excoveralls, "~> 0.17", only: :test}
    ]
  end
end
