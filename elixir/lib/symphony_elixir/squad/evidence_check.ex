defmodule SymphonyElixir.Squad.EvidenceCheck do
  @moduledoc """
  Validates the Codex squad evidence contract used before handoff.
  """

  alias SymphonyElixir.Config.Schema

  @required_sections ["## Scope", "## CTO Plan", "## Implementation", "## Verification"]

  @type context :: %{
          optional(String.t()) => map() | [String.t()]
        }

  @spec default_context() :: context()
  def default_context do
    %{
      "model_roles" => Schema.Agent.default_model_roles(),
      "required_verifiers" => Schema.Agent.default_required_verifiers()
    }
  end

  @spec validate_file(Path.t()) :: :ok | {:error, [String.t()]}
  def validate_file(path), do: validate_file(path, default_context())

  @spec validate_file(Path.t(), context()) :: :ok | {:error, [String.t()]}
  def validate_file(path, context) when is_binary(path) and is_map(context) do
    case File.read(path) do
      {:ok, markdown} -> validate(markdown, context)
      {:error, reason} -> {:error, ["unable to read #{path}: #{inspect(reason)}"]}
    end
  end

  @spec validate(String.t()) :: :ok | {:error, [String.t()]}
  def validate(markdown), do: validate(markdown, default_context())

  @spec validate(String.t(), context()) :: :ok | {:error, [String.t()]}
  def validate(markdown, context) when is_binary(markdown) and is_map(context) do
    model_roles = context |> Map.get("model_roles", %{}) |> normalize_model_roles()
    required_verifiers = context |> Map.get("required_verifiers", []) |> normalize_required_verifiers()

    errors =
      []
      |> require_sections(markdown)
      |> require_role(markdown, "## CTO Plan", "cto", Map.get(model_roles, "cto"))
      |> require_role(markdown, "## Implementation", "implementer", Map.get(model_roles, "implementer"))
      |> require_verifier_rows(markdown, required_verifiers, model_roles)

    if errors == [] do
      :ok
    else
      {:error, Enum.reverse(errors)}
    end
  end

  defp require_sections(errors, markdown) do
    Enum.reduce(@required_sections, errors, fn section, acc ->
      if String.contains?(markdown, section), do: acc, else: ["missing section #{section}" | acc]
    end)
  end

  defp require_role(errors, _markdown, _section, _role, nil), do: ["missing configured model for role" | errors]

  defp require_role(errors, markdown, section, role, model) do
    body = section_body(markdown, section)
    normalized_body = String.downcase(body)

    cond do
      body == "" ->
        ["missing section #{section}" | errors]

      not String.contains?(normalized_body, String.downcase(role)) ->
        ["#{section} must mention role #{role}" | errors]

      not String.contains?(normalized_body, String.downcase(model)) ->
        ["#{section} must mention model #{model}" | errors]

      true ->
        errors
    end
  end

  defp require_verifier_rows(errors, markdown, required_verifiers, model_roles) do
    body = section_body(markdown, "## Verification")

    Enum.reduce(required_verifiers, errors, fn verifier, acc ->
      model = Map.get(model_roles, verifier)

      cond do
        body == "" ->
          ["missing section ## Verification" | acc]

        is_nil(model) ->
          ["missing configured model for verifier #{verifier}" | acc]

        verifier_pass_row?(body, verifier, model) ->
          acc

        true ->
          ["## Verification must include PASS for #{verifier} (#{model})" | acc]
      end
    end)
  end

  defp verifier_pass_row?(body, verifier, model) do
    verifier = String.downcase(verifier)
    model = String.downcase(model)

    body
    |> String.split("\n")
    |> Enum.any?(fn line ->
      normalized_line = String.downcase(line)

      String.contains?(normalized_line, verifier) and String.contains?(normalized_line, model) and
        Regex.match?(~r/\bPASS\b/i, line)
    end)
  end

  defp section_body(markdown, section) do
    escaped_section = Regex.escape(section)

    case Regex.run(~r/^#{escaped_section}\s*$/m, markdown, return: :index) do
      [{start, length}] ->
        content_start = heading_line_end(markdown, start + length)
        content = binary_part(markdown, content_start, byte_size(markdown) - content_start)

        case Regex.run(~r/^##\s+/m, content, return: :index) do
          [{next_start, _next_length}] -> binary_part(content, 0, next_start)
          nil -> content
        end

      nil ->
        ""
    end
  end

  defp heading_line_end(markdown, offset) do
    case :binary.match(markdown, "\n", scope: {offset, byte_size(markdown) - offset}) do
      {newline_at, 1} -> newline_at + 1
      :nomatch -> byte_size(markdown)
    end
  end

  defp normalize_model_roles(roles) when is_map(roles) do
    Map.new(roles, fn {role, model} -> {to_string(role), to_string(model)} end)
  end

  defp normalize_model_roles(_roles), do: %{}

  defp normalize_required_verifiers(verifiers) when is_list(verifiers) do
    Enum.map(verifiers, &to_string/1)
  end

  defp normalize_required_verifiers(_verifiers), do: []
end
