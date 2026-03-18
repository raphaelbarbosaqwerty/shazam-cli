defmodule Mix.Tasks.Shazam.Task do
  @moduledoc "Create a task in a running Shazam company."
  @shortdoc "Create a new task"

  use Mix.Task

  alias Shazam.CLI.{Formatter, Helpers}

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args,
      switches: [to: :string, company: :string, description: :string],
      aliases: [c: :company, t: :to, d: :description]
    )

    title = Enum.join(positional, " ")

    if title == "" do
      Formatter.error("Usage: mix shazam.task \"Task description\" [--to agent_name]")
      System.halt(1)
    end

    Helpers.ensure_app()

    company = Helpers.find_company(opts)

    unless company do
      Formatter.error("No company running. Start with 'mix shazam.start'")
      System.halt(1)
    end

    task_opts = [description: opts[:description] || title]
    task_opts = if opts[:to], do: [{:to, opts[:to]} | task_opts], else: task_opts

    case Shazam.assign(company, title, task_opts) do
      {:ok, task} ->
        task_id = task["id"] || task[:id] || "?"
        assigned = task["assigned_to"] || task[:assigned_to] || opts[:to] || "auto"
        Formatter.success("Task created: ##{task_id}")
        Formatter.info("\"#{title}\" → #{assigned}")
      {:error, reason} ->
        Formatter.error("Failed: #{inspect(reason)}")
    end
  end
end
