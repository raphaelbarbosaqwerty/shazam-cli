defmodule Shazam.CLI.TuiPort.Commands do
  @moduledoc """
  Thin dispatcher that routes `/command` input to the appropriate submodule.
  """

  alias Shazam.CLI.TuiPort.Commands.{System, Tasks, Agents, Review, Tools}
  alias Shazam.CLI.TuiPort.Helpers

  # ── System commands ──────────────────────────────────────

  def handle_command("/quit" = cmd, state), do: System.handle_command(cmd, state)
  def handle_command("/exit" = cmd, state), do: System.handle_command(cmd, state)
  def handle_command("/help" = cmd, state), do: System.handle_command(cmd, state)
  def handle_command("/start" = cmd, state), do: System.handle_command(cmd, state)
  def handle_command("/stop" = cmd, state), do: System.handle_command(cmd, state)
  def handle_command("/pause" = cmd, state), do: System.handle_command(cmd, state)
  def handle_command("/resume" = cmd, state), do: System.handle_command(cmd, state)
  def handle_command("/dashboard" = cmd, state), do: System.handle_command(cmd, state)
  def handle_command("/status" = cmd, state), do: System.handle_command(cmd, state)
  def handle_command("/config" = cmd, state), do: System.handle_command(cmd, state)
  def handle_command("/clear" = cmd, state), do: System.handle_command(cmd, state)
  def handle_command("/memory" = cmd, state), do: System.handle_command(cmd, state)
  def handle_command("/health" = cmd, state), do: System.handle_command(cmd, state)
  def handle_command("/workspaces" = cmd, state), do: System.handle_command(cmd, state)
  def handle_command("/plugins reload" = cmd, state), do: System.handle_command(cmd, state)
  def handle_command("/plugins" = cmd, state), do: System.handle_command(cmd, state)

  # ── Agent management commands ────────────────────────────

  def handle_command("/agent presets" = cmd, state), do: Agents.handle_command(cmd, state)
  def handle_command("/agent add " <> _ = cmd, state), do: Agents.handle_command(cmd, state)
  def handle_command("/agent edit " <> _ = cmd, state), do: Agents.handle_command(cmd, state)
  def handle_command("/agent remove " <> _ = cmd, state), do: Agents.handle_command(cmd, state)
  def handle_command("/agents --init" = cmd, state), do: Agents.handle_command(cmd, state)
  def handle_command("/agents" = cmd, state), do: Agents.handle_command(cmd, state)
  def handle_command("/org" = cmd, state), do: Agents.handle_command(cmd, state)
  def handle_command("/team create " <> _ = cmd, state), do: Agents.handle_command(cmd, state)
  def handle_command("/team templates" = cmd, state), do: Agents.handle_command(cmd, state)

  # ── Review commands ──────────────────────────────────────

  def handle_command("/review " <> _ = cmd, state), do: Review.handle_command(cmd, state)

  # ── Tool commands (plan, qa, memory-bank) ────────────────

  def handle_command("/memory-bank --update" = cmd, state), do: Tools.handle_command(cmd, state)
  def handle_command("/memory-bank" = cmd, state), do: Tools.handle_command(cmd, state)
  def handle_command("/plan " <> _ = cmd, state), do: Tools.handle_command(cmd, state)
  def handle_command("/qa" <> _ = cmd, state), do: Tools.handle_command(cmd, state)

  # ── Task commands ────────────────────────────────────────

  def handle_command("/tasks" <> _ = cmd, state), do: Tasks.handle_command(cmd, state)
  def handle_command("/task " <> _ = cmd, state), do: Tasks.handle_command(cmd, state)
  def handle_command("/approve-all" = cmd, state), do: Tasks.handle_command(cmd, state)
  def handle_command("/aa" = cmd, state), do: Tasks.handle_command(cmd, state)
  def handle_command("/approve" <> _ = cmd, state), do: Tasks.handle_command(cmd, state)
  def handle_command("/reject " <> _ = cmd, state), do: Tasks.handle_command(cmd, state)
  def handle_command("/msg " <> _ = cmd, state), do: Tasks.handle_command(cmd, state)
  def handle_command("/auto-approve" <> _ = cmd, state), do: Tasks.handle_command(cmd, state)
  def handle_command("/pause-task " <> _ = cmd, state), do: Tasks.handle_command(cmd, state)
  def handle_command("/resume-task " <> _ = cmd, state), do: Tasks.handle_command(cmd, state)
  def handle_command("/kill-task " <> _ = cmd, state), do: Tasks.handle_command(cmd, state)
  def handle_command("/retry-all" = cmd, state), do: Tasks.handle_command(cmd, state)
  def handle_command("/retry-task " <> _ = cmd, state), do: Tasks.handle_command(cmd, state)
  def handle_command("/delete-task " <> _ = cmd, state), do: Tasks.handle_command(cmd, state)
  def handle_command("/start-task " <> _ = cmd, state), do: Tasks.handle_command(cmd, state)
  def handle_command("/search " <> _ = cmd, state), do: Tasks.handle_command(cmd, state)
  def handle_command("/export" <> _ = cmd, state), do: Tasks.handle_command(cmd, state)

  # ── Unknown command ──────────────────────────────────────

  def handle_command("/" <> cmd, state) do
    Helpers.send_event(state.port, "system", "error", "Unknown command: /#{cmd}. Type /help for available commands.")
    state
  end

  # ── Plain text → task creation (catch-all) ───────────────

  def handle_command(text, state) when text != "", do: Tasks.handle_command(text, state)

  def handle_command(_, state), do: state
end
