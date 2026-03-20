defmodule Shazam.MixProject do
  use Mix.Project

  @version "0.8.0"

  def project do
    [
      app: :shazam,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      escript: escript()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Shazam.Application, []}
    ]
  end

  defp escript do
    [
      main_module: Shazam.CLI,
      name: "shazam-cli",
      app: nil  # don't auto-start OTP app — CLI manages it
    ]
  end

  defp deps do
    [
      {:claude_code, "~> 0.29"},
      {:bandit, "~> 1.0"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"},
      {:cors_plug, "~> 3.0"},
      {:websock_adapter, "~> 0.5"},
      {:exqlite, "~> 0.27"},
      {:yaml_elixir, "~> 2.9"},

      # Phoenix LiveView stack
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:esbuild, "~> 0.9", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_pubsub, "~> 2.1"}
    ]
  end

  defp aliases do
    [
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind shazam", "esbuild shazam"],
      "assets.deploy": [
        "tailwind shazam --minify",
        "esbuild shazam --minify",
        "phx.digest"
      ]
    ]
  end
end
