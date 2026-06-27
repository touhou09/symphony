defmodule SymphonyElixir.SquadRun do
  @moduledoc """
  Role artifacts and handoff evidence for Codex squad-style runs.
  """

  @type role :: :cto | :implementer | :verifier | :final_verifier
  @type verdict :: :pass | :fail | :inconclusive
  @type status :: :not_run | :passed | :failed | :blocked

  defmodule Artifact do
    @moduledoc false
    defstruct role: nil,
              model: nil,
              status: :not_run,
              notes: nil,
              verdict: :inconclusive,
              payload_summary: nil
  end

  @roles [:cto, :implementer, :verifier, :final_verifier]

  defstruct [
    :issue_identifier,
    :issue_title,
    role_artifacts: %{},
    notes: []
  ]

  @type t :: %__MODULE__{
          issue_identifier: String.t() | nil,
          issue_title: String.t() | nil,
          role_artifacts: %{
            optional(role) => %Artifact{
              role: role | nil,
              model: String.t() | nil,
              status: status,
              notes: String.t() | nil,
              verdict: verdict,
              payload_summary: String.t() | nil
            }
          },
          notes: [String.t()]
        }

  @doc """
  Create a run artifact for an issue with empty role state.
  """
  @spec new(map() | nil) :: t()
  def new(issue) when is_map(issue) do
    issue_identifier = Map.get(issue, :identifier) || Map.get(issue, "identifier")
    issue_title = Map.get(issue, :title) || Map.get(issue, "title")

    %__MODULE__{
      issue_identifier: issue_identifier,
      issue_title: issue_title,
      role_artifacts:
        @roles
        |> Enum.into(%{}, fn role ->
          {role, %Artifact{role: role, model: nil}}
        end)
    }
  end

  def new(_issue), do: %__MODULE__{}

  @doc """
  Ordered role list used by squad orchestration.
  """
  @spec roles() :: [role()]
  def roles, do: @roles

  @doc """
  Whether verifier and final_verifier both passed.
  """
  @spec handoff_allowed?(t()) :: boolean()
  def handoff_allowed?(%__MODULE__{role_artifacts: artifacts}) when is_map(artifacts) do
    Map.get(artifacts, :verifier, %Artifact{}).verdict == :pass and
      Map.get(artifacts, :final_verifier, %Artifact{}).verdict == :pass
  end

  def handoff_allowed?(_run), do: false

  @doc """
  Add or update the model configured for one role.
  """
  @spec put_model(t(), role(), String.t() | nil) :: t()
  def put_model(%__MODULE__{role_artifacts: artifacts} = run, role, model) when is_atom(role) do
    artifact = Map.get(artifacts, role, %Artifact{role: role, model: model})
    %{run | role_artifacts: Map.put(artifacts, role, %{artifact | model: model})}
  end

  @doc """
  Save turn completion into role artifact and infer status/verdict.
  """
  @spec put_completion(t(), role(), String.t() | nil, map() | nil, keyword()) :: t()
  def put_completion(%__MODULE__{role_artifacts: _artifacts} = run, role, model, completion, opts \\ [])
      when is_atom(role) do
    run = put_model(run, role, model)

    artifact =
      case Map.get(run.role_artifacts, role) do
        %Artifact{} = current_artifact -> current_artifact
        _ -> %Artifact{role: role, model: model}
      end

    notes = Keyword.get(opts, :notes)

    updated_artifact = %Artifact{
      artifact
      | status: infer_status(role, completion),
        verdict: infer_verdict(role, completion),
        notes: notes || artifact.notes,
        payload_summary: summarize_payload(completion)
    }

    %{run | role_artifacts: Map.put(run.role_artifacts, role, updated_artifact)}
  end

  @doc """
  Add a runtime blocker note.
  """
  @spec put_limitation(t(), String.t()) :: t()
  def put_limitation(%__MODULE__{} = run, note) when is_binary(note) do
    %{run | notes: Enum.uniq([note | run.notes])}
  end

  @doc """
  Render markdown suitable for handoff validation and audit.
  """
  @spec render_markdown(t()) :: String.t()
  def render_markdown(%__MODULE__{} = run) do
    """
    ## Scope
    - Issue: #{run.issue_identifier || "unknown"} - #{run.issue_title || "unknown"}
    - Roles: CTO, implementer, verifier, final_verifier

    ## CTO Plan
    - Execute roles in order: cto -> implementer -> verifier -> final_verifier.
    - Use configured model per role when supported by runtime.
    - Persist one artifact per role and gate handoff on verifier and final_verifier PASS.

    ## Implementation
    #{render_role_blocks(run)}

    ## Verification
    | Role | Model | Status | Verdict |
    | --- | --- | --- | --- |
    #{verification_rows(run)}

    Notes:
    #{render_notes(run)}
    """
    |> String.trim()
  end

  @doc """
  Write evidence markdown to a file.
  """
  @spec write_markdown(t(), Path.t()) :: :ok | {:error, term()}
  def write_markdown(%__MODULE__{} = run, path) when is_binary(path) do
    path
    |> Path.dirname()
    |> File.mkdir_p()

    File.write(path, render_markdown(run))
  end

  defp infer_status(role, completion) when role in [:verifier, :final_verifier] and is_map(completion) do
    if infer_verdict(role, completion) == :pass, do: :passed, else: :failed
  end

  defp infer_status(_role, completion) when is_map(completion), do: :passed
  defp infer_status(_role, _completion), do: :failed

  defp infer_verdict(role, completion) when role in [:verifier, :final_verifier] do
    infer_verdict_text(find_verdict_text(completion))
  end

  defp infer_verdict(_role, _completion), do: :pass

  defp infer_verdict_text(value) when is_binary(value) do
    normalized = String.trim(String.downcase(value))

    cond do
      normalized in ["pass", "passed", "ok", "success", "succeeded", "approved"] -> :pass
      normalized in ["fail", "failed", "blocked", "block", "not pass"] -> :fail
      true -> :inconclusive
    end
  end

  defp infer_verdict_text(_value), do: :inconclusive

  defp find_verdict_text(completion) when is_map(completion) do
    candidate_paths = [
      ["params", "verdict"],
      ["result", "verdict"],
      ["params", "result", "verdict"],
      ["params", "status"],
      ["result", "status"]
    ]

    Enum.find_value(candidate_paths, fn path -> get_in(completion, path) end) ||
      Enum.find_value(candidate_paths, fn path -> get_in(completion, Enum.map(path, &String.to_atom/1)) end) ||
      completion_text(completion)
  end

  defp find_verdict_text(_completion), do: nil

  defp completion_text(completion) when is_map(completion) do
    Enum.find_value(["output", "text", "notes"], fn key ->
      value = Map.get(completion, key)

      cond do
        is_binary(value) and String.match?(value, ~r/\b(pass|fail|blocked)\b/i) -> value
        true -> nil
      end
    end)
  end

  defp completion_text(_completion), do: nil

  defp summarize_payload(completion) when is_map(completion) do
    completion
    |> Map.take(["method", "params", "result"])
    |> inspect()
    |> String.trim()
  end

  defp summarize_payload(_completion), do: nil

  defp render_role_blocks(%__MODULE__{role_artifacts: artifacts}) do
    Enum.map_join(@roles, "\n", fn role ->
      artifact = Map.get(artifacts, role, %Artifact{role: role})

      """
      ### #{role_to_name(role)}
      - Model: `#{artifact.model || "unconfigured"}`
      - Status: #{format_status(artifact.status)}
      - Verdict: #{format_verdict(artifact.verdict)}
      - Payload summary: #{artifact.payload_summary || "none"}
      - Notes: #{artifact.notes || "none"}
      """
    end)
  end

  defp verification_rows(%__MODULE__{role_artifacts: artifacts}) do
    Enum.map_join(@roles, "\n", fn role ->
      artifact = Map.get(artifacts, role, %Artifact{role: role})
      "| #{role_to_name(role)} | #{artifact.model || "unconfigured"} | #{format_status(artifact.status)} | #{format_verdict(artifact.verdict)} |"
    end)
  end

  defp render_notes(%__MODULE__{notes: notes}) do
    case notes do
      [] -> "- none"
      _ -> Enum.map_join(notes, "\n", &"- #{&1}")
    end
  end

  defp format_status(:not_run), do: "not run"
  defp format_status(:passed), do: "passed"
  defp format_status(:failed), do: "failed"
  defp format_status(:blocked), do: "blocked"
  defp format_status(_), do: "unknown"

  defp format_verdict(:pass), do: "PASS"
  defp format_verdict(:fail), do: "FAIL"
  defp format_verdict(:inconclusive), do: "inconclusive"
  defp format_verdict(_), do: "not run"

  defp role_to_name(:cto), do: "CTO"
  defp role_to_name(:implementer), do: "Implementer"
  defp role_to_name(:verifier), do: "Verifier"
  defp role_to_name(:final_verifier), do: "Final Verifier"
  defp role_to_name(_), do: "Unknown"
end
