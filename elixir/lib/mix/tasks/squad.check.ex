defmodule Mix.Tasks.Squad.Check do
  use Mix.Task

  alias SymphonyElixir.Workflow

  @shortdoc "Validate Codex squad evidence against expected handoff contract"

  @moduledoc """
  Validates squad evidence files produced by the Codex squad flow.

  Usage:

      mix squad.check --file path/to/evidence.md --workflow path/to/WORKFLOW.md
  """

  @required_headings ["## Scope", "## CTO Plan", "## Implementation", "## Verification"]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args, strict: [file: :string, workflow: :string, help: :boolean], aliases: [h: :help])

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        evidence_path = required_opt(opts, :file)
        workflow_path = Keyword.get(opts, :workflow, Workflow.workflow_file_path())

        with {:ok, _workflow} <- read_workflow(workflow_path),
             {:ok, evidence} <- read_file(evidence_path),
             :ok <- validate_headings(evidence),
             :ok <- validate_verification_table(evidence) do
          Mix.shell().info("squad.check: evidence looks valid for workflow #{workflow_path}")
        end
    end
  end

  defp required_opt(opts, key) do
    case opts[key] do
      nil -> Mix.raise("Missing required option --#{key}")
      value -> value
    end
  end

  defp read_workflow(path) when is_binary(path) do
    case Workflow.load(path) do
      {:ok, workflow} ->
        {:ok, workflow}

      {:error, reason} ->
        Mix.raise("Unable to load workflow #{path}: #{inspect(reason)}")
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> Mix.raise("Unable to read evidence file #{path}: #{inspect(reason)}")
    end
  end

  defp validate_headings(evidence) do
    missing = required_headings_missing(evidence)

    if missing != [] do
      Mix.raise("Missing required squad sections: #{Enum.join(missing, ", ")}")
    end

    headings = heading_positions(evidence)
    required_positions = Enum.map(@required_headings, fn heading -> Map.get(headings, heading) end)

    if required_positions != Enum.sort(required_positions) do
      Mix.raise("Required headings are out of order")
    end

    :ok
  end

  defp required_headings_missing(evidence) do
    Enum.filter(@required_headings, fn heading ->
      heading_positions(evidence) |> Map.get(heading) |> is_nil()
    end)
  end

  defp heading_positions(text) do
    Enum.reduce(@required_headings, %{}, fn heading, acc ->
      case :binary.match(text, heading) do
        :nomatch -> acc
        {index, _} -> Map.put(acc, heading, index)
      end
    end)
  end

  defp validate_verification_table(evidence) do
    rows = parse_verification_rows(evidence)

    case {Map.get(rows, "verifier"), Map.get(rows, "final_verifier")} do
      {nil, _} ->
        Mix.raise("Missing verifier row in evidence verification table")

      {_, nil} ->
        Mix.raise("Missing final_verifier row in evidence verification table")

      {verifier, final_verifier} ->
        if verify_pass?(verifier) and verify_pass?(final_verifier) do
          :ok
        else
          Mix.raise("Handoff blocked: verifier/final_verifier must both be PASS (found verifier=#{Map.get(verifier, :verdict)}, final_verifier=#{Map.get(final_verifier, :verdict)})")
        end
    end
  end

  defp parse_verification_rows(evidence) do
    Enum.reduce(String.split(evidence, ~r/\R/, trim: true), %{}, fn line, acc ->
      case Regex.named_captures(
             ~r/^\|\s*(?<role>[^|]+)\s*\|\s*(?<model>[^|]+)\s*\|\s*(?<status>[^|]+)\s*\|\s*(?<verdict>[^|]+)\s*\|$/,
             line
           ) do
        nil ->
          acc

        captures ->
          role = normalize_role(captures["role"])

          Map.put(acc, role, %{
            model: captures["model"],
            status: captures["status"],
            verdict: captures["verdict"]
          })
      end
    end)
  end

  defp normalize_role(role) when is_binary(role) do
    role
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, "_")
  end

  defp verify_pass?(%{verdict: verdict}) when is_binary(verdict) do
    normalized = String.trim(verdict) |> String.downcase()
    normalized == "pass" || normalized == "passed" || normalized == "success" || normalized == "approved"
  end

  defp verify_pass?(_), do: false
end
