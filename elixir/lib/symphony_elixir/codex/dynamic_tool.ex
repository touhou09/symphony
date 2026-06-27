defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{Config, Tracker}
  alias SymphonyElixir.Linear.Client, as: LinearClient

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @tracker_get_issue_tool "tracker_get_issue"
  @tracker_list_comments_tool "tracker_list_comments"
  @tracker_add_comment_tool "tracker_add_comment"
  @tracker_update_comment_tool "tracker_update_comment"
  @tracker_transition_issue_tool "tracker_transition_issue"

  @issue_id_property %{
    "type" => "string",
    "description" => "Tracker issue id or key, for example a Jira key such as SYM-6."
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    if tool in supported_tool_names(opts) do
      execute_supported(tool, arguments, opts)
    else
      unsupported_tool_response(tool, opts)
    end
  end

  defp execute_supported(@linear_graphql_tool, arguments, opts), do: execute_linear_graphql(arguments, opts)
  defp execute_supported(@tracker_get_issue_tool, arguments, opts), do: execute_tracker_get_issue(arguments, opts)
  defp execute_supported(@tracker_list_comments_tool, arguments, opts), do: execute_tracker_list_comments(arguments, opts)
  defp execute_supported(@tracker_add_comment_tool, arguments, opts), do: execute_tracker_add_comment(arguments, opts)
  defp execute_supported(@tracker_update_comment_tool, arguments, opts), do: execute_tracker_update_comment(arguments, opts)
  defp execute_supported(@tracker_transition_issue_tool, arguments, opts), do: execute_tracker_transition_issue(arguments, opts)

  defp unsupported_tool_response(tool, opts) do
    failure_response(%{
      "error" => %{
        "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
        "supportedTools" => supported_tool_names(opts)
      }
    })
  end

  @spec tool_specs(keyword()) :: [map()]
  def tool_specs(opts \\ []) do
    case Keyword.get(opts, :tracker_kind) || configured_tracker_kind() do
      kind when kind in ["jira", "memory"] -> tracker_tool_specs()
      _ -> [linear_graphql_spec()]
    end
  end

  defp configured_tracker_kind do
    Config.settings!().tracker.kind
  rescue
    _ -> "linear"
  end

  defp linear_graphql_spec do
    %{
      "name" => @linear_graphql_tool,
      "description" => @linear_graphql_description,
      "inputSchema" => @linear_graphql_input_schema
    }
  end

  defp tracker_tool_specs do
    [
      %{
        "name" => @tracker_get_issue_tool,
        "description" => "Fetch the current tracker issue through Symphony's configured tracker adapter.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["issueId"],
          "properties" => %{"issueId" => @issue_id_property}
        }
      },
      %{
        "name" => @tracker_list_comments_tool,
        "description" => "List existing tracker issue comments through Symphony's configured tracker adapter.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["issueId"],
          "properties" => %{"issueId" => @issue_id_property}
        }
      },
      %{
        "name" => @tracker_add_comment_tool,
        "description" => "Add a progress/workpad comment to the current tracker issue through Symphony's configured tracker adapter.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["issueId", "body"],
          "properties" => %{
            "issueId" => @issue_id_property,
            "body" => %{"type" => "string", "description" => "Markdown/plain-text comment body."}
          }
        }
      },
      %{
        "name" => @tracker_update_comment_tool,
        "description" => "Update an existing tracker issue comment through Symphony's configured tracker adapter.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["issueId", "commentId", "body"],
          "properties" => %{
            "issueId" => @issue_id_property,
            "commentId" => %{"type" => "string", "description" => "Tracker comment id to update."},
            "body" => %{"type" => "string", "description" => "Replacement Markdown/plain-text comment body."}
          }
        }
      },
      %{
        "name" => @tracker_transition_issue_tool,
        "description" => "Move the current tracker issue to a target state through Symphony's configured tracker adapter.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["issueId", "state"],
          "properties" => %{
            "issueId" => @issue_id_property,
            "state" => %{"type" => "string", "description" => "Target tracker status/state name."}
          }
        }
      }
    ]
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &LinearClient.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(linear_tool_error_payload(reason))
    end
  end

  defp execute_tracker_get_issue(arguments, opts) do
    tracker_fetcher = Keyword.get(opts, :tracker_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, issue_id} <- normalize_issue_id(arguments),
         {:ok, issues} <- tracker_fetcher.([issue_id]) do
      case issues do
        [issue | _] ->
          dynamic_tool_response(true, encode_payload(%{"issue" => issue}))

        [] ->
          failure_response(%{"error" => %{"message" => "Tracker issue not found.", "issueId" => issue_id}})
      end
    else
      {:error, reason} -> failure_response(tracker_tool_error_payload(reason))
    end
  end

  defp execute_tracker_list_comments(arguments, opts) do
    tracker_lister = Keyword.get(opts, :tracker_comment_lister, &Tracker.list_comments/1)

    with {:ok, issue_id} <- normalize_issue_id(arguments),
         {:ok, comments} <- tracker_lister.(issue_id) do
      dynamic_tool_response(true, encode_payload(%{"comments" => comments, "issueId" => issue_id}))
    else
      {:error, reason} -> failure_response(tracker_tool_error_payload(reason))
    end
  end

  defp execute_tracker_add_comment(arguments, opts) do
    tracker_commenter = Keyword.get(opts, :tracker_commenter, &Tracker.create_comment/2)

    with {:ok, issue_id, body} <- normalize_tracker_comment_arguments(arguments),
         :ok <- tracker_comment_write_gate(body, opts),
         :ok <- tracker_commenter.(issue_id, body) do
      dynamic_tool_response(true, encode_payload(%{"ok" => true, "issueId" => issue_id}))
    else
      {:error, reason} -> failure_response(tracker_tool_error_payload(reason))
    end
  end

  defp execute_tracker_update_comment(arguments, opts) do
    tracker_comment_updater = Keyword.get(opts, :tracker_comment_updater, &Tracker.update_comment/3)

    with {:ok, issue_id, comment_id, body} <- normalize_tracker_update_comment_arguments(arguments),
         :ok <- tracker_comment_write_gate(body, opts),
         :ok <- tracker_comment_updater.(issue_id, comment_id, body) do
      dynamic_tool_response(true, encode_payload(%{"ok" => true, "issueId" => issue_id, "commentId" => comment_id}))
    else
      {:error, reason} -> failure_response(tracker_tool_error_payload(reason))
    end
  end

  defp execute_tracker_transition_issue(arguments, opts) do
    tracker_transitioner = Keyword.get(opts, :tracker_transitioner, &Tracker.update_issue_state/2)

    with {:ok, issue_id, state_name} <- normalize_tracker_transition_arguments(arguments),
         :ok <- tracker_transitioner.(issue_id, state_name) do
      dynamic_tool_response(true, encode_payload(%{"ok" => true, "issueId" => issue_id, "state" => state_name}))
    else
      {:error, reason} -> failure_response(tracker_tool_error_payload(reason))
    end
  end

  defp tracker_comment_write_gate(body, opts) do
    cond do
      not Keyword.get(opts, :require_workspace_diff_for_tracker_comments, false) ->
        :ok

      runtime_blocker_comment?(body) ->
        :ok

      true ->
        case workspace_change_status(Keyword.get(opts, :workspace)) do
          :changed -> :ok
          _ -> {:error, :workspace_diff_required_for_tracker_comment}
        end
    end
  end

  defp runtime_blocker_comment?(body) when is_binary(body) do
    normalized = String.downcase(body)

    String.contains?(body, "<!-- symphony-runtime-blocker:") or
      String.contains?(normalized, "### runtime blocker") or
      String.contains?(normalized, "## blocker")
  end

  defp runtime_blocker_comment?(_body), do: false

  defp workspace_change_status(path) when is_binary(path) and path != "" do
    case System.cmd("git", ["-C", path, "status", "--porcelain=v1", "--branch"], stderr_to_stdout: true) do
      {output, 0} -> parse_git_status(output)
      {_output, _status} -> :unknown
    end
  rescue
    _ -> :unknown
  end

  defp workspace_change_status(_path), do: :unknown

  defp parse_git_status(output) when is_binary(output) do
    lines = output |> String.split("\n", trim: true)

    cond do
      Enum.any?(lines, &(not String.starts_with?(&1, "## "))) -> :changed
      Enum.any?(lines, &String.contains?(&1, ["ahead", "gone"])) -> :changed
      true -> :clean
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} -> {:ok, query, variables}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp normalize_tracker_comment_arguments(arguments) when is_map(arguments) do
    with {:ok, issue_id} <- normalize_issue_id(arguments),
         {:ok, body} <- normalize_text_argument(arguments, ["body", "comment", "text", :body, :comment, :text], :missing_comment_body) do
      {:ok, issue_id, body}
    end
  end

  defp normalize_tracker_comment_arguments(_arguments), do: {:error, :invalid_tracker_arguments}

  defp normalize_tracker_update_comment_arguments(arguments) when is_map(arguments) do
    with {:ok, issue_id} <- normalize_issue_id(arguments),
         {:ok, comment_id} <- normalize_comment_id(arguments),
         {:ok, body} <- normalize_text_argument(arguments, ["body", "comment", "text", :body, :comment, :text], :missing_comment_body) do
      {:ok, issue_id, comment_id, body}
    end
  end

  defp normalize_tracker_update_comment_arguments(_arguments), do: {:error, :invalid_tracker_arguments}

  defp normalize_tracker_transition_arguments(arguments) when is_map(arguments) do
    with {:ok, issue_id} <- normalize_issue_id(arguments),
         {:ok, state_name} <- normalize_text_argument(arguments, ["state", "status", "targetState", :state, :status, :target_state], :missing_target_state) do
      {:ok, issue_id, state_name}
    end
  end

  defp normalize_tracker_transition_arguments(_arguments), do: {:error, :invalid_tracker_arguments}

  defp normalize_issue_id(arguments) when is_binary(arguments) do
    normalize_text_value(arguments, :missing_issue_id)
  end

  defp normalize_issue_id(arguments) when is_map(arguments) do
    normalize_text_argument(arguments, ["issueId", "issue_id", "id", "identifier", "key", :issue_id, :issueId, :id, :identifier, :key], :missing_issue_id)
  end

  defp normalize_issue_id(_arguments), do: {:error, :invalid_tracker_arguments}

  defp normalize_comment_id(arguments) when is_map(arguments) do
    normalize_text_argument(arguments, ["commentId", "comment_id", "comment", "id", :comment_id, :commentId, :comment, :id], :missing_comment_id)
  end

  defp normalize_text_argument(arguments, keys, missing_reason) do
    keys
    |> Enum.find_value(&Map.get(arguments, &1))
    |> normalize_text_value(missing_reason)
  end

  defp normalize_text_value(value, missing_reason) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, missing_reason}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_text_value(_value, missing_reason), do: {:error, missing_reason}

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    payload |> json_safe() |> Jason.encode!(pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp json_safe(nil), do: nil
  defp json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_safe(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp json_safe(%Date{} = value), do: Date.to_iso8601(value)
  defp json_safe(%Time{} = value), do: Time.to_iso8601(value)
  defp json_safe(%_{} = value), do: value |> Map.from_struct() |> json_safe()
  defp json_safe(value) when is_map(value), do: Map.new(value, fn {key, val} -> {to_string(key), json_safe(val)} end)
  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: value

  defp linear_tool_error_payload(:missing_query) do
    %{"error" => %{"message" => "`linear_graphql` requires a non-empty `query` string."}}
  end

  defp linear_tool_error_payload(:invalid_arguments) do
    %{"error" => %{"message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."}}
  end

  defp linear_tool_error_payload(:invalid_variables) do
    %{"error" => %{"message" => "`linear_graphql.variables` must be a JSON object when provided."}}
  end

  defp linear_tool_error_payload(:missing_linear_api_token) do
    %{"error" => %{"message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."}}
  end

  defp linear_tool_error_payload({:linear_api_status, status}) do
    %{"error" => %{"message" => "Linear GraphQL request failed with HTTP #{status}.", "status" => status}}
  end

  defp linear_tool_error_payload({:linear_api_request, reason}) do
    %{"error" => %{"message" => "Linear GraphQL request failed before receiving a successful response.", "reason" => inspect(reason)}}
  end

  defp linear_tool_error_payload(reason) do
    %{"error" => %{"message" => "Linear GraphQL tool execution failed.", "reason" => inspect(reason)}}
  end

  defp tracker_tool_error_payload(:missing_issue_id), do: tracker_tool_message("Tracker tool requires a non-empty `issueId` string.")
  defp tracker_tool_error_payload(:missing_comment_id), do: tracker_tool_message("`tracker_update_comment` requires a non-empty `commentId` string.")
  defp tracker_tool_error_payload(:missing_comment_body), do: tracker_tool_message("Tracker comment tools require a non-empty `body` string.")
  defp tracker_tool_error_payload(:missing_target_state), do: tracker_tool_message("`tracker_transition_issue` requires a non-empty `state` string.")

  defp tracker_tool_error_payload(:workspace_diff_required_for_tracker_comment) do
    tracker_tool_message(
      "Tracker comment writes are blocked until the workspace has a code, test, docs, or squad evidence diff. Edit files first, or write a `### Runtime Blocker` comment with the concrete blocker."
    )
  end

  defp tracker_tool_error_payload(:invalid_tracker_arguments), do: tracker_tool_message("Tracker tools expect a JSON object with the required fields.")

  defp tracker_tool_error_payload(reason) do
    %{"error" => %{"message" => "Tracker tool execution failed.", "reason" => inspect(reason)}}
  end

  defp tracker_tool_message(message), do: %{"error" => %{"message" => message}}

  defp supported_tool_names(opts) do
    Enum.map(tool_specs(opts), & &1["name"])
  end
end
