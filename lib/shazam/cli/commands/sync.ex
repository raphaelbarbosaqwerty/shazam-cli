defmodule Shazam.CLI.Commands.Sync do
  @moduledoc "Sync IDE agent configs (Claude/Gemini/Cursor/Codex)."

  def run(args) do
    preview = "--preview" in args
    port = System.get_env("SHAZAM_PORT") || "4040"
    url = "http://localhost:#{port}/api/sync"

    payload = Jason.encode!(%{preview: preview})
    headers = [{~c"Content-Type", ~c"application/json"}]

    IO.puts(if preview, do: "\n⚡ Sync Preview\n", else: "\n⚡ Syncing IDE configs...\n")

    case :httpc.request(:post, {String.to_charlist(url), headers, ~c"application/json", String.to_charlist(payload)}, [timeout: 15_000], []) do
      {:ok, {{_, 200, _}, _, body}} ->
        data = Jason.decode!(List.to_string(body))
        count = data["count"] || 0
        providers = data["providers"] || []

        IO.puts("  #{IO.ANSI.green()}✓#{IO.ANSI.reset()} #{count} files #{if preview, do: "would be generated", else: "synced"}")
        IO.puts("  Providers: #{Enum.join(providers, ", ")}")

        if preview do
          files = data["files"] || []
          Enum.each(files, fn f ->
            IO.puts("    #{f["type"]}: #{f["path"]}")
          end)
        end

        IO.puts("")

      {:ok, {{_, code, _}, _, _}} ->
        IO.puts("  #{IO.ANSI.red()}Daemon returned HTTP #{code}#{IO.ANSI.reset()}")

      {:error, reason} ->
        IO.puts("  #{IO.ANSI.red()}Daemon not running#{IO.ANSI.reset()} (#{inspect(reason)})")
        IO.puts("  Start with: shazam start")
    end
  end
end
