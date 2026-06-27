defmodule Mix.Tasks.Squad.Check do
  use Mix.Task

  alias SymphonyElixir.{Config, Workflow}
  alias SymphonyElixir.Squad.EvidenceCheck

  @shortdoc "Validate Codex squad evidence markdown"

  @moduledoc """
  Validates a Codex squad evidence markdown file against the role/model routing
  in `WORKFLOW.md`.

  Usage:

      mix squad.check --file docs/codex-squad-evidence.md --workflow WORKFLOW.md
  """

  @switches [file: :string, workflow: :string, help: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches, aliases: [h: :help])

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        file_path = required_opt(opts, :file)

        with {:ok, context} <- squad_context(opts),
             :ok <- EvidenceCheck.validate_file(file_path, context) do
          Mix.shell().info("squad.check: evidence contract OK")
        else
          {:error, errors} when is_list(errors) ->
            Enum.each(errors, &Mix.shell().error("ERROR: #{&1}"))
            Mix.raise("squad.check failed with #{length(errors)} evidence error(s)")

          {:error, message} ->
            Mix.raise(message)
        end
    end
  end

  defp required_opt(opts, key) do
    case opts[key] do
      nil -> Mix.raise("Missing required option --#{key}")
      value -> value
    end
  end

  defp squad_context(opts) do
    case opts[:workflow] do
      nil ->
        {:ok, EvidenceCheck.default_context()}

      workflow_path ->
        Workflow.set_workflow_file_path(Path.expand(workflow_path))

        case Config.settings() do
          {:ok, _settings} -> {:ok, Config.squad_prompt_context()}
          {:error, reason} -> {:error, "Unable to load workflow #{workflow_path}: #{inspect(reason)}"}
        end
    end
  end
end
