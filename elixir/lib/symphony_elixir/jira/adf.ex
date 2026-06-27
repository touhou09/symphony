defmodule SymphonyElixir.Jira.ADF do
  @moduledoc """
  Minimal Atlassian Document Format (ADF) helpers.

  Jira Cloud REST v3 returns rich text (descriptions, comments) as ADF JSON and
  expects ADF JSON on writes. Symphony only needs a faithful-enough plain-text
  projection for prompts, and a simple text -> ADF document for comment writes.
  """

  @doc """
  Flatten an ADF document (or already-plain string) into plain text.

  Returns `nil` for `nil` so the normalized issue keeps a nil description rather
  than an empty string.
  """
  @spec to_text(term()) :: String.t() | nil
  def to_text(nil), do: nil
  def to_text(text) when is_binary(text), do: text

  def to_text(%{} = node) do
    node
    |> node_to_text()
    |> collapse_blank_lines()
    |> String.trim()
    |> nil_if_empty()
  end

  def to_text(_other), do: nil

  @doc """
  Build a minimal ADF document from plain text, preserving line breaks as
  separate paragraphs. Suitable for the REST v3 comment `body` field.
  """
  @spec from_text(String.t()) :: map()
  def from_text(text) when is_binary(text) do
    paragraphs =
      text
      |> String.split("\n")
      |> Enum.map(&paragraph_node/1)

    %{"type" => "doc", "version" => 1, "content" => paragraphs}
  end

  defp paragraph_node("") do
    %{"type" => "paragraph", "content" => []}
  end

  defp paragraph_node(line) do
    %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => line}]}
  end

  # Text leaf.
  defp node_to_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text

  # Explicit line break.
  defp node_to_text(%{"type" => "hardBreak"}), do: "\n"

  # Block-level nodes get trailing newlines so paragraphs/headings/list items separate.
  defp node_to_text(%{"type" => type, "content" => content})
       when is_list(content) and type in ~w(paragraph heading listItem codeBlock blockquote) do
    children_to_text(content) <> "\n"
  end

  # Any other container: just concatenate children.
  defp node_to_text(%{"content" => content}) when is_list(content) do
    children_to_text(content)
  end

  defp node_to_text(_node), do: ""

  defp children_to_text(content) do
    Enum.map_join(content, "", &node_to_text/1)
  end

  defp collapse_blank_lines(text) do
    String.replace(text, ~r/\n{3,}/, "\n\n")
  end

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(text), do: text
end
