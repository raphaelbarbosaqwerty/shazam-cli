defmodule Shazam.CLI.Commands.Doctor do
  @moduledoc "System health diagnostics."

  def run do
    IO.puts("\n⚡ Shazam Doctor\n")

    port = System.get_env("SHAZAM_PORT") || "4040"
    url = "http://localhost:#{port}/api/doctor"

    case :httpc.request(:get, {String.to_charlist(url), []}, [timeout: 5000], []) do
      {:ok, {{_, 200, _}, _, body}} ->
        data = Jason.decode!(List.to_string(body))
        checks = data["checks"] || []

        Enum.each(checks, fn check ->
          icon = case check["status"] do
            "ok" -> IO.ANSI.green() <> "✓" <> IO.ANSI.reset()
            "warning" -> IO.ANSI.yellow() <> "!" <> IO.ANSI.reset()
            "error" -> IO.ANSI.red() <> "✗" <> IO.ANSI.reset()
            _ -> "?"
          end
          IO.puts("  [#{icon}] #{check["name"]}: #{check["message"]}")
        end)

        passed = data["passed"] || 0
        total = data["total"] || 0
        failed = data["failed"] || 0
        warnings = data["warnings"] || 0

        IO.puts("\n  #{passed}/#{total} passed, #{failed} failed, #{warnings} warnings\n")

      {:ok, {{_, code, _}, _, _}} ->
        IO.puts("  #{IO.ANSI.red()}Daemon returned HTTP #{code}#{IO.ANSI.reset()}")

      {:error, reason} ->
        IO.puts("  #{IO.ANSI.red()}Daemon not running#{IO.ANSI.reset()} (#{inspect(reason)})")
        IO.puts("  Start with: shazam start")
    end
  end
end
