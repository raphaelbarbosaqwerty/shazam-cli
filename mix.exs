defmodule ShazamCLI.MixProject do
  use Mix.Project

  @version "1.1.1"

  def project do
    [
      app: :shazam_cli,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
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
      # Shazam Core — the backend engine
      {:shazam, path: "../shazam-core"},
      {:yaml_elixir, "~> 2.9"}
    ]
  end
end
