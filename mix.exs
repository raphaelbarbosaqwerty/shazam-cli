defmodule Shazam.MixProject do
  use Mix.Project

  @version "0.2.0"

  def project do
    [
      app: :shazam,
      version: @version,
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
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
      name: "shazam",
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
      {:yaml_elixir, "~> 2.9"}
    ]
  end
end
