defmodule Mix.Tasks.Ticket.Check do
  use Mix.Task

  alias SymphonyElixir.{Config, Workflow}
  alias SymphonyElixir.Ticket.ContentCheck

  @shortdoc "Validate tracker ticket description markdown"

  @moduledoc """
  Validates a tracker ticket description markdown file against the ticket content
  contract in `WORKFLOW.md`.

  Usage:

      mix ticket.check --file docs/example-ticket.md --workflow WORKFLOW.md
      mix ticket.check --file docs/example-ticket.md --strict
  """

  @switches [file: :string, workflow: :string, strict: :boolean, help: :boolean]

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

        with {:ok, markdown} <- read_file(file_path),
             {:ok, options} <- check_options(opts),
             :ok <- ContentCheck.validate(markdown, options) do
          Mix.shell().info("ticket.check: ticket content contract OK")
        else
          {:error, errors} when is_list(errors) ->
            Enum.each(errors, &Mix.shell().error("ERROR: #{&1}"))
            Mix.raise("ticket.check failed with #{length(errors)} ticket content error(s)")

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

  defp read_file(path) do
    case File.read(path) do
      {:ok, markdown} -> {:ok, markdown}
      {:error, reason} -> {:error, "unable to read #{path}: #{inspect(reason)}"}
    end
  end

  defp check_options(opts) do
    cond do
      opts[:strict] ->
        {:ok,
         [
           required_sections: ContentCheck.default_required_sections(),
           require_acceptance_checkboxes: true,
           require_validation_checkboxes: true
         ]}

      is_binary(opts[:workflow]) ->
        Workflow.set_workflow_file_path(Path.expand(opts[:workflow]))

        case Config.settings() do
          {:ok, _settings} -> {:ok, Config.ticket_content_check_options()}
          {:error, reason} -> {:error, "Unable to load workflow #{opts[:workflow]}: #{inspect(reason)}"}
        end

      true ->
        {:ok, [required_sections: ContentCheck.default_required_sections()]}
    end
  end
end
