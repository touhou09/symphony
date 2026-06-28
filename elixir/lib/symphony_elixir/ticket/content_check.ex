defmodule SymphonyElixir.Ticket.ContentCheck do
  @moduledoc """
  Validates tracker ticket descriptions before an unattended Codex run starts.

  The check is intentionally content-shape oriented. It does not judge whether a
  requirement is good; it verifies that the ticket carries the minimum sections
  an autonomous squad run needs to plan, implement, and verify without guessing.
  """

  alias SymphonyElixir.Linear.Issue

  @canonical_sections %{
    "background" => ["background", "context", "problem", "배경"],
    "goal" => ["goal", "objective", "desired outcome", "목표"],
    "scope" => ["scope", "in scope", "범위"],
    "acceptance criteria" => ["acceptance criteria", "acceptance", "done when", "완료 조건"],
    "validation" => ["validation", "test plan", "testing", "tests", "검증", "테스트"],
    "agent flow" => ["agent flow", "agent workflow", "squad flow", "에이전트 플로우"],
    "handoff evidence" => ["handoff evidence", "evidence", "verification evidence", "인계 증거"]
  }

  @default_required_sections ["Background", "Scope", "Acceptance Criteria", "Validation"]

  @type validation_options :: [
          required_sections: [String.t()],
          require_acceptance_checkboxes: boolean(),
          require_validation_checkboxes: boolean()
        ]

  @doc """
  Default strict sections for SYM Jira tickets.
  """
  @spec default_required_sections() :: [String.t()]
  def default_required_sections, do: @default_required_sections

  @doc """
  Validate a normalized tracker issue.
  """
  @spec validate_issue(Issue.t(), validation_options()) :: :ok | {:error, [String.t()]}
  def validate_issue(%Issue{description: description}, opts \\ []) do
    validate(description, opts)
  end

  @doc """
  Validate raw ticket description markdown.
  """
  @spec validate(String.t() | nil, validation_options()) :: :ok | {:error, [String.t()]}
  def validate(description, opts \\ []) do
    required_sections = normalize_required_sections(Keyword.get(opts, :required_sections, []))
    require_acceptance_checkboxes = Keyword.get(opts, :require_acceptance_checkboxes, false)
    require_validation_checkboxes = Keyword.get(opts, :require_validation_checkboxes, false)
    timeout_ms = Keyword.get(opts, :validation_timeout_ms, 2_000)

    if !is_integer(timeout_ms) or timeout_ms <= 0 do
      {:error, ["validation_timeout_ms must be a positive integer"]}
    else
      sections = parse_sections(description)

      task =
        Task.async(fn ->
          []
          |> require_description(description)
          |> require_sections(sections, required_sections)
          |> require_checkboxes(sections, "Acceptance Criteria", require_acceptance_checkboxes)
          |> require_checkboxes(sections, "Validation", require_validation_checkboxes)
          |> Enum.reverse()
        end)

      errors =
        case Task.yield(task, timeout_ms) do
          nil ->
            Task.shutdown(task, :brutal_kill)
            ["ticket validation timed out after #{timeout_ms}ms"]

          {:exit, _} ->
            Task.shutdown(task, :brutal_kill)
            ["ticket validation raised an unexpected error"]

          {:ok, validation_errors} ->
            validation_errors
        end

      if errors == [], do: :ok, else: {:error, errors}
    end
  end

  @doc """
  Returns true when a configured check would actually reject malformed content.
  """
  @spec enabled?(validation_options()) :: boolean()
  def enabled?(opts) when is_list(opts) do
    normalize_required_sections(Keyword.get(opts, :required_sections, [])) != [] or
      Keyword.get(opts, :require_acceptance_checkboxes, false) or
      Keyword.get(opts, :require_validation_checkboxes, false)
  end

  @doc """
  Format preflight errors for tracker comments and logs.
  """
  @spec format_errors([String.t()]) :: String.t()
  def format_errors(errors) when is_list(errors), do: Enum.join(errors, "; ")

  @doc """
  Build a tracker comment that explains why dispatch was blocked.
  """
  @spec blocker_comment(Issue.t(), [String.t()]) :: String.t()
  def blocker_comment(%Issue{} = issue, errors) when is_list(errors) do
    identifier = issue.identifier || issue.id || "ticket"

    body = Enum.map_join(errors, "\n", &"- #{&1}")

    """
    ## Symphony Ticket Preflight Blocker

    Symphony did not start an unattended Codex run for `#{identifier}` because the ticket body is missing required execution details.

    #{body}

    Add the missing sections/checklist items, then move or keep the ticket in an active state so Symphony can pick it up again.
    """
    |> String.trim()
  end

  defp require_description(errors, description) do
    if blank?(description), do: ["ticket description is required" | errors], else: errors
  end

  defp require_sections(errors, sections, required_sections) do
    Enum.reduce(required_sections, errors, fn section, acc ->
      case section_body(sections, section) do
        nil -> ["missing section ## #{section}" | acc]
        body when body == "" -> ["section ## #{section} has no content" | acc]
        _body -> acc
      end
    end)
  end

  defp require_checkboxes(errors, _sections, _section, false), do: errors

  defp require_checkboxes(errors, sections, section, true) do
    case section_body(sections, section) do
      nil -> add_missing_section_error(errors, section)
      body -> if checklist_items?(body), do: errors, else: ["section ## #{section} must include checklist items" | errors]
    end
  end

  defp normalize_required_sections(sections) when is_list(sections) do
    sections
    |> Enum.map(&(to_string(&1) |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_required_sections(_sections), do: []

  defp add_missing_section_error(errors, section) do
    error = "missing section ## #{section}"

    if error in errors, do: errors, else: [error | errors]
  end

  @heading_matcher ~r/^\s{0,3}(\#{1,6})\s+(.+?)\s*#*\s*$/

  defp parse_sections(description) when is_binary(description) do
    lines =
      description
      |> expand_collapsed_headings()
      |> String.split("\n", trim: false)

    {current, sections, buffer} =
      Enum.reduce(lines, {nil, %{}, []}, fn line, {current_canonical, sections, buffer} ->
        case heading_match(line) do
          nil ->
            {current_canonical, sections, [line | buffer]}

          canonical ->
            sections = store_section_body(sections, current_canonical, buffer)
            {canonical, sections, []}
        end
      end)

    store_section_body(sections, current, buffer)
  end

  defp parse_sections(_description), do: %{}

  @collapsed_heading_pattern ~r/(^|[^\n])(\#{1,6})\s*(Acceptance Criteria|Desired Outcome|Agent Workflow|Handoff Evidence|Verification Evidence|Agent Flow|Squad Flow|Test Plan|Done When|In Scope|Background|Validation|Objective|Acceptance|Evidence|Testing|Context|Problem|Scope|Tests|Goal|배경|목표|범위|완료 조건|검증|테스트|에이전트 플로우|인계 증거)(?=\s|#|:|-|$|[A-Z0-9가-힣])/u

  defp expand_collapsed_headings(description) do
    Regex.replace(@collapsed_heading_pattern, description, fn _match, prefix, hashes, title ->
      boundary = if prefix == "", do: "", else: prefix <> "\n"
      boundary <> hashes <> " " <> title <> "\n"
    end)
  end

  defp store_section_body(sections, nil, _buffer), do: sections

  defp store_section_body(sections, canonical, buffer) do
    Map.put_new(sections, canonical, Enum.reverse(buffer) |> Enum.join("\n") |> String.trim())
  end

  defp heading_match(line) do
    case Regex.run(@heading_matcher, line) do
      [_, _hashes, title] -> canonical_section(clean_heading_title(title))
      _ -> bare_heading_match(line)
    end
  end

  defp bare_heading_match(line) do
    line
    |> clean_heading_title()
    |> known_canonical_section()
    |> case do
      canonical when is_binary(canonical) and canonical != "" -> canonical
      _ -> nil
    end
  end

  defp clean_heading_title(title) do
    title
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> String.trim_trailing(":")
  end

  defp canonical_section(title) do
    normalized = normalize_heading(title)

    Enum.find_value(@canonical_sections, normalized, fn {canonical, aliases} ->
      if normalized in aliases, do: canonical
    end)
  end

  defp known_canonical_section(title) do
    normalized = normalize_heading(title)

    Enum.find_value(@canonical_sections, fn {canonical, aliases} ->
      if normalized in aliases, do: canonical
    end)
  end

  defp section_body(sections, section) do
    Map.get(sections, canonical_section(section))
  end

  defp checklist_items?(body) when is_binary(body) do
    Regex.match?(~r/^\s*(?:[-*]\s+)?\[[ xX]\]\s+\S/m, body)
  end

  defp normalize_heading(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
    |> String.trim_trailing(":")
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true
end
