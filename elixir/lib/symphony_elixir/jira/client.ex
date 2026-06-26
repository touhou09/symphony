defmodule SymphonyElixir.Jira.Client do
  @moduledoc """
  Thin Jira Cloud REST v3 client for polling candidate issues and performing
  the tracker write operations (transitions, comments).

  Mirrors `SymphonyElixir.Linear.Client` but speaks REST/JQL instead of GraphQL.
  Auth is HTTP Basic with `email:api_token`. All HTTP goes through `request/4`,
  whose `:request_fun` option is overridable in tests to avoid the network.
  """

  require Logger
  alias SymphonyElixir.Config
  alias SymphonyElixir.Jira.{ADF, Normalizer}

  @issue_page_size 50
  @search_fields ~w(summary description priority status assignee labels issuelinks created updated)
  @max_error_body_log_bytes 1_000

  # ------------------------------------------------------------------
  # Read callbacks (SymphonyElixir.Tracker)
  # ------------------------------------------------------------------

  @spec fetch_candidate_issues(keyword()) :: {:ok, [SymphonyElixir.Linear.Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(opts \\ []) do
    tracker = Config.settings!().tracker

    with :ok <- require_config(tracker),
         {:ok, assignee_filter} <- routing_assignee_filter(opts) do
      tracker.project_slug
      |> candidate_jql(tracker.active_states, tracker.assignee)
      |> search_all(assignee_filter, opts)
    end
  end

  @spec fetch_issues_by_states([String.t()], keyword()) ::
          {:ok, [SymphonyElixir.Linear.Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names, opts \\ []) when is_list(state_names) do
    normalized_states = state_names |> Enum.map(&to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker

      with :ok <- require_config(tracker) do
        # No assignee clause: terminal cleanup must see issues regardless of assignee.
        tracker.project_slug
        |> states_jql(normalized_states)
        |> search_all(nil, opts)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()], keyword()) ::
          {:ok, [SymphonyElixir.Linear.Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids, opts \\ []) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, assignee_filter} <- routing_assignee_filter(opts) do
          fetch_by_ids(ids, assignee_filter, opts)
        end
    end
  end

  # ------------------------------------------------------------------
  # Write operations (used by SymphonyElixir.Jira.Adapter)
  # ------------------------------------------------------------------

  @spec get_transitions(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_transitions(issue_id, opts \\ []) when is_binary(issue_id) do
    request(:get, "/rest/api/3/issue/#{issue_id}/transitions", nil, opts)
  end

  @spec transition_issue(String.t(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def transition_issue(issue_id, transition_id, opts \\ [])
      when is_binary(issue_id) and is_binary(transition_id) do
    request(:post, "/rest/api/3/issue/#{issue_id}/transitions", %{"transition" => %{"id" => transition_id}}, opts)
  end

  @spec add_comment(String.t(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def add_comment(issue_id, body, opts \\ []) when is_binary(issue_id) and is_binary(body) do
    request(:post, "/rest/api/3/issue/#{issue_id}/comment", %{"body" => ADF.from_text(body)}, opts)
  end

  @spec myself(keyword()) :: {:ok, map()} | {:error, term()}
  def myself(opts \\ []) do
    request(:get, "/rest/api/3/myself", nil, opts)
  end

  # ------------------------------------------------------------------
  # JQL construction
  # ------------------------------------------------------------------

  defp candidate_jql(project_key, active_states, assignee) do
    [project_clause(project_key), status_clause(active_states)]
    |> Kernel.++(assignee_clause(assignee))
    |> Enum.join(" AND ")
    |> Kernel.<>(" ORDER BY priority ASC, created ASC")
  end

  defp states_jql(project_key, states) do
    Enum.join([project_clause(project_key), status_clause(states)], " AND ")
  end

  defp ids_jql(ids), do: "id IN (#{Enum.join(ids, ",")})"

  defp project_clause(project_key), do: ~s(project = "#{project_key}")

  defp status_clause(states) do
    quoted = states |> Enum.map(&~s("#{&1}")) |> Enum.join(",")
    "status IN (#{quoted})"
  end

  defp assignee_clause("me"), do: ["assignee = currentUser()"]
  defp assignee_clause(account_id) when is_binary(account_id), do: [~s(assignee = "#{account_id}")]
  defp assignee_clause(_assignee), do: []

  # ------------------------------------------------------------------
  # Search + pagination
  # ------------------------------------------------------------------

  defp search_all(jql, assignee_filter, opts) do
    search_page(jql, assignee_filter, opts, nil, [])
  end

  defp search_page(jql, assignee_filter, opts, page_token, acc) do
    body =
      %{"jql" => jql, "fields" => @search_fields, "maxResults" => @issue_page_size}
      |> maybe_put_page_token(page_token)

    with {:ok, response} <- request(:post, "/rest/api/3/search/jql", body, opts),
         {:ok, issues, next_token} <- decode_search(response, assignee_filter) do
      updated_acc = Enum.reverse(issues, acc)

      case next_token do
        nil -> {:ok, Enum.reverse(updated_acc)}
        token -> search_page(jql, assignee_filter, opts, token, updated_acc)
      end
    end
  end

  defp fetch_by_ids(ids, assignee_filter, opts) do
    ids
    |> Enum.chunk_every(@issue_page_size)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      case search_all(ids_jql(chunk), assignee_filter, opts) do
        {:ok, issues} -> {:cont, {:ok, Enum.reverse(issues, acc)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, sort_by_requested_ids(Enum.reverse(acc), ids)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sort_by_requested_ids(issues, ids) do
    order = ids |> Enum.with_index() |> Map.new()
    fallback = map_size(order)
    Enum.sort_by(issues, fn issue -> Map.get(order, issue.id, fallback) end)
  end

  defp maybe_put_page_token(body, nil), do: body
  defp maybe_put_page_token(body, token), do: Map.put(body, "nextPageToken", token)

  defp decode_search(%{"issues" => nodes} = body, assignee_filter) when is_list(nodes) do
    endpoint = Config.settings!().tracker.endpoint

    issues =
      nodes
      |> Enum.map(&Normalizer.normalize_issue(&1, assignee_filter, endpoint))
      |> Enum.reject(&is_nil/1)

    {:ok, issues, next_page_token(body)}
  end

  defp decode_search(%{"errorMessages" => errors}, _assignee_filter) do
    {:error, {:jira_api_errors, errors}}
  end

  defp decode_search(_unknown, _assignee_filter), do: {:error, :jira_unknown_payload}

  defp next_page_token(%{"isLast" => true}), do: nil
  defp next_page_token(%{"nextPageToken" => token}) when is_binary(token) and token != "", do: token
  defp next_page_token(_body), do: nil

  # ------------------------------------------------------------------
  # Assignee resolution
  # ------------------------------------------------------------------

  defp routing_assignee_filter(opts) do
    case Config.settings!().tracker.assignee do
      nil -> {:ok, nil}
      assignee -> build_assignee_filter(assignee, opts)
    end
  end

  defp build_assignee_filter(assignee, opts) when is_binary(assignee) do
    case String.trim(assignee) do
      "" -> {:ok, nil}
      "me" -> resolve_myself_filter(opts)
      account_id -> {:ok, %{configured_assignee: assignee, match_values: MapSet.new([account_id])}}
    end
  end

  defp resolve_myself_filter(opts) do
    case myself(opts) do
      {:ok, %{"accountId" => account_id}} when is_binary(account_id) ->
        {:ok, %{configured_assignee: "me", match_values: MapSet.new([account_id])}}

      {:ok, _body} ->
        {:error, :missing_jira_account_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ------------------------------------------------------------------
  # HTTP
  # ------------------------------------------------------------------

  defp require_config(tracker) do
    cond do
      is_nil(tracker.api_key) -> {:error, :missing_jira_api_token}
      is_nil(tracker.email) -> {:error, :missing_jira_email}
      is_nil(tracker.project_slug) -> {:error, :missing_jira_project_key}
      true -> :ok
    end
  end

  defp request(method, path, body, opts) do
    with {:ok, headers} <- auth_headers() do
      url = build_url(path)
      request_fun = Keyword.get(opts, :request_fun, &default_request/4)

      case request_fun.(method, url, body, headers) do
        {:ok, %{status: status, body: response_body}} when status in 200..299 ->
          {:ok, response_body}

        {:ok, response} ->
          Logger.error("Jira REST #{method} #{path} failed status=#{response.status}#{error_body(response)}")
          {:error, {:jira_api_status, response.status}}

        {:error, reason} ->
          Logger.error("Jira REST #{method} #{path} failed: #{inspect(reason)}")
          {:error, {:jira_api_request, reason}}
      end
    end
  end

  defp build_url(path) do
    Config.settings!().tracker.endpoint
    |> String.trim_trailing("/")
    |> Kernel.<>(path)
  end

  defp auth_headers do
    tracker = Config.settings!().tracker

    cond do
      is_nil(tracker.api_key) ->
        {:error, :missing_jira_api_token}

      is_nil(tracker.email) ->
        {:error, :missing_jira_email}

      true ->
        token = Base.encode64("#{tracker.email}:#{tracker.api_key}")

        {:ok,
         [
           {"Authorization", "Basic #{token}"},
           {"Content-Type", "application/json"},
           {"Accept", "application/json"}
         ]}
    end
  end

  defp default_request(:get, url, _body, headers) do
    Req.get(url, headers: headers, connect_options: [timeout: 30_000])
  end

  defp default_request(:post, url, body, headers) do
    Req.post(url, headers: headers, json: body, connect_options: [timeout: 30_000])
  end

  defp error_body(%{body: body}) when is_binary(body) do
    summary =
      body
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    summary =
      if byte_size(summary) > @max_error_body_log_bytes do
        binary_part(summary, 0, @max_error_body_log_bytes) <> "...<truncated>"
      else
        summary
      end

    " body=" <> inspect(summary)
  end

  defp error_body(%{body: body}), do: " body=" <> inspect(body, limit: 20)
  defp error_body(_response), do: ""
end
