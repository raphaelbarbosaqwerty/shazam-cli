defmodule Shazam.Backend.EventNormalizer do
  @moduledoc """
  Normalizes events from any backend into a unified internal format.
  Used by the Orchestrator to broadcast events without caring about the backend.

  Internal event types:
    {:text_delta, text}          — partial text chunk
    {:text, text}                — complete text block
    {:tool_use, name, input}     — tool invocation
    {:tool_complete, name, out}  — tool result
    {:assistant, [sub_events]}   — complete assistant message with sub-events
    {:result_ok, text}           — successful final result
    {:result_error, reason}      — failed final result
    :ignore                      — skip this event
  """

  @doc "Normalizes an event using the given backend module."
  def normalize(event, backend_module) do
    backend_module.normalize_event(event)
  end

  @doc "Extracts touched file paths from a tool_use event."
  def extract_touched_file({:tool_use, tool, input})
      when tool in ["Edit", "Write", "StrReplace"] do
    path = input["file_path"] || input[:file_path] || input["path"] || input[:path]
    if path, do: [path], else: []
  end
  def extract_touched_file(_), do: []

  @doc "Checks if an event is a text delta."
  def text_delta?({:text_delta, _}), do: true
  def text_delta?(_), do: false

  @doc "Checks if an event is a final result."
  def result?({:result_ok, _}), do: true
  def result?({:result_error, _}), do: true
  def result?(_), do: false
end
