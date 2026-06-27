defmodule SymphonyElixir.Jira.Normalizer do
  @moduledoc """
  Normalizes raw Jira Cloud REST v3 issue payloads into the shared
  `SymphonyElixir.Linear.Issue` struct the orchestrator consumes.

  The struct name stays `Linear.Issue` on purpose: the orchestrator pattern
  matches that exact struct everywhere, so every tracker adapter emits it.
  """

  alias SymphonyElixir.Jira.ADF
  alias SymphonyElixir.Linear.Issue

  @priority_by_name %{
    "highest" => 1,
    "high" => 2,
    "medium" => 3,
    "low" => 4,
    "lowest" => 5
  }

  @blocked_by_inward "is blocked by"

  @doc """
  Build a normalized issue from a raw Jira issue map.

  `assignee_filter` mirrors the Linear adapter shape:
  `nil` (no filter) or `%{match_values: MapSet.t()}` of acceptable accountIds.
  `endpoint` is the Jira site base URL used to synthesize the browse URL.
  """
  @spec normalize_issue(map(), map() | nil, String.t() | nil) :: Issue.t() | nil
  def normalize_issue(issue, assignee_filter, endpoint) when is_map(issue) do
    fields = Map.get(issue, "fields", %{})
    key = issue["key"]
    assignee = Map.get(fields, "assignee")

    %Issue{
      id: issue["id"],
      identifier: key,
      title: fields["summary"],
      description: ADF.to_text(fields["description"]),
      priority: parse_priority(fields["priority"]),
      state: get_in(fields, ["status", "name"]),
      branch_name: nil,
      url: browse_url(endpoint, key),
      assignee_id: assignee_account_id(assignee),
      blocked_by: extract_blockers(fields),
      labels: extract_labels(fields),
      assigned_to_worker: assigned_to_worker?(assignee, assignee_filter),
      created_at: parse_datetime(fields["created"]),
      updated_at: parse_datetime(fields["updated"])
    }
  end

  def normalize_issue(_issue, _assignee_filter, _endpoint), do: nil

  defp browse_url(endpoint, key) when is_binary(endpoint) and is_binary(key) do
    String.trim_trailing(endpoint, "/") <> "/browse/" <> key
  end

  defp browse_url(_endpoint, _key), do: nil

  defp parse_priority(%{"name" => name}) when is_binary(name) do
    Map.get(@priority_by_name, String.downcase(String.trim(name)))
  end

  defp parse_priority(_priority), do: nil

  defp assignee_account_id(%{"accountId" => account_id}) when is_binary(account_id), do: account_id
  defp assignee_account_id(_assignee), do: nil

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    case assignee_account_id(assignee) do
      nil -> false
      account_id -> MapSet.member?(match_values, account_id)
    end
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp extract_labels(%{"labels" => labels}) when is_list(labels) do
    labels
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
  end

  defp extract_labels(_fields), do: []

  defp extract_blockers(%{"issuelinks" => links}) when is_list(links) do
    Enum.flat_map(links, &blocker_from_link/1)
  end

  defp extract_blockers(_fields), do: []

  defp blocker_from_link(%{"type" => %{"inward" => inward}, "inwardIssue" => %{} = blocker})
       when is_binary(inward) do
    if String.downcase(String.trim(inward)) == @blocked_by_inward do
      [
        %{
          id: blocker["id"],
          identifier: blocker["key"],
          state: get_in(blocker, ["fields", "status", "name"])
        }
      ]
    else
      []
    end
  end

  defp blocker_from_link(_link), do: []

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(normalize_offset(raw)) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_raw), do: nil

  # Jira returns basic-format offsets like `+0900`; ISO8601 extended wants `+09:00`.
  # No-op for `Z` or already-colon offsets.
  defp normalize_offset(raw) do
    Regex.replace(~r/([+-]\d{2})(\d{2})$/, raw, "\\1:\\2")
  end
end
