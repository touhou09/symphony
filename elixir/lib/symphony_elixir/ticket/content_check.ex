defmodule SymphonyElixir.Ticket.ContentCheck do
  @moduledoc """
  Validates tracker ticket descriptions before unattended Codex runs.
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

  @spec default_required_sections() :: [String.t()]
  def default_required_sections, do: @default_required_sections

  @spec validate_issue(Issue.t(), validation_options()) :: :ok | {:error, [String.t()]}
  def validate_issue(%Issue{description: description}, opts \\ []) do
    validate(description, opts)
  end

  @spec validate(String.t() | nil, validation_options()) :: :ok | {:error, [String.t()]}
  def validate(description, opts \\ []) do
    required_sections = normalize_required_sections(Keyword.get(opts, :required_sections, []))
    require_acceptance_checkboxes = Keyword.get(opts, :require_acceptance_checkboxes, false)
    require_validation_checkboxes = Keyword.get(opts, :require_validation_checkboxes, false)

    errors =
      []
      |> require_description(description)
      |> require_sections(description, required_sections)
      |> require_checkboxes(description, "Acceptance Criteria", require_acceptance_checkboxes)
      |> require_checkboxes(description, "Validation", require_validation_checkboxes)
      |> Enum.reverse()

    if errors == [], do: :ok, else: {:error, errors}
  end

  @spec format_errors([String.t()]) :: String.t()
  def format_errors(errors) when is_list(errors), do: Enum.join(errors, "; ")

  @spec blocker_comment(Issue.t(), [String.t()]) :: String.t()
  def blocker_comment(%Issue{} = issue, errors) when is_list(errors) do
    identifier = issue.identifier || issue.id || "ticket"

    body =
      errors
      |> Enum.map(&"- #{&1}")
      |> Enum.join("\n")

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

  defp require_sections(errors, description, required_sections) do
    sections = parse_sections(description)

    Enum.reduce(required_sections, errors, fn section, acc ->
      case section_body(sections, section) do
        nil -> ["missing section ## #{section}" | acc]
        "" -> ["section ## #{section} has no content" | acc]
        _body -> acc
      end
    end)
  end

  defp require_checkboxes(errors, _description, _section, false), do: errors

  defp require_checkboxes(errors, description, section, true) do
    sections = parse_sections(description)

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

  defp parse_sections(description) when is_binary(description) do
    matches = Regex.scan(~r/^\s{0,3}(\#{1,6})\s+(.+?)\s*#*\s*$/m, description, return: :index)

    matches
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {match, index}, acc ->
      [{heading_start, _heading_len}, _level, {title_start, title_len}] = match
      title = binary_part(description, title_start, title_len) |> clean_heading_title()
      canonical = canonical_section(title)
      next_heading_start = next_heading_start(matches, index, byte_size(description))
      body_start = heading_line_end(description, heading_start)
      body = binary_part(description, body_start, next_heading_start - body_start) |> String.trim()

      Map.put_new(acc, canonical, body)
    end)
  end

  defp parse_sections(_description), do: %{}

  defp next_heading_start(matches, index, default_start) do
    case Enum.at(matches, index + 1) do
      [{start, _len} | _rest] -> start
      _ -> default_start
    end
  end

  defp heading_line_end(description, heading_start) do
    case :binary.match(description, "\n", scope: {heading_start, byte_size(description) - heading_start}) do
      {newline_at, 1} -> newline_at + 1
      :nomatch -> byte_size(description)
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

  defp section_body(sections, section) do
    Map.get(sections, canonical_section(section))
  end

  defp checklist_items?(body) when is_binary(body) do
    Regex.match?(~r/^\s*[-*]\s+\[[ xX]\]\s+\S/m, body)
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
