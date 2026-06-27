defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  test "tool_specs advertises the linear_graphql input contract" do
    assert [
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{
                   "query" => _,
                   "variables" => _
                 },
                 "required" => ["query"],
                 "type" => "object"
               },
               "name" => "linear_graphql"
             }
           ] = DynamicTool.tool_specs()

    assert description =~ "Linear"
  end

  test "tool_specs advertises tracker tools for jira tracker" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "jira")

    assert DynamicTool.tool_specs() |> Enum.map(& &1["name"]) == [
             "tracker_get_issue",
             "tracker_list_comments",
             "tracker_add_comment",
             "tracker_update_comment",
             "tracker_transition_issue"
           ]
  end

  test "jira tracker mode rejects linear_graphql and advertises tracker tools" do
    response = DynamicTool.execute("linear_graphql", %{"query" => "query Viewer { viewer { id } }"}, tracker_kind: "jira")

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "linear_graphql".),
               "supportedTools" => ["tracker_get_issue", "tracker_list_comments", "tracker_add_comment", "tracker_update_comment", "tracker_transition_issue"]
             }
           }
  end

  test "tracker_get_issue returns json-safe issue payload" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "tracker_get_issue",
        %{"issueId" => "SYM-6"},
        tracker_kind: "jira",
        tracker_fetcher: fn ids ->
          send(test_pid, {:tracker_fetcher_called, ids})

          {:ok,
           [
             %Issue{
               id: "10652",
               identifier: "SYM-6",
               title: "Implement true Codex role orchestration",
               state: "미해결",
               created_at: ~U[2026-06-26 15:23:40Z]
             }
           ]}
        end
      )

    assert_received {:tracker_fetcher_called, ["SYM-6"]}
    assert response["success"] == true

    assert Jason.decode!(response["output"])["issue"] |> Map.take(["id", "identifier", "state", "created_at"]) == %{
             "id" => "10652",
             "identifier" => "SYM-6",
             "state" => "미해결",
             "created_at" => "2026-06-26T15:23:40Z"
           }
  end

  test "tracker comment tools delegate list, create, update, and transitions" do
    test_pid = self()

    list_response =
      DynamicTool.execute(
        "tracker_list_comments",
        %{"issueId" => "SYM-6"},
        tracker_kind: "jira",
        tracker_comment_lister: fn issue_id ->
          send(test_pid, {:tracker_list_comments_called, issue_id})
          {:ok, [%{"id" => "11381", "body" => "## Codex Workpad"}]}
        end
      )

    comment_response =
      DynamicTool.execute(
        "tracker_add_comment",
        %{"issueId" => "SYM-6", "body" => "## Codex Workpad\n\n- [ ] Start"},
        tracker_kind: "jira",
        tracker_commenter: fn issue_id, body ->
          send(test_pid, {:tracker_comment_called, issue_id, body})
          :ok
        end
      )

    update_response =
      DynamicTool.execute(
        "tracker_update_comment",
        %{"issueId" => "SYM-6", "commentId" => "11381", "body" => "## Codex Workpad\n\n- [x] Start"},
        tracker_kind: "jira",
        tracker_comment_updater: fn issue_id, comment_id, body ->
          send(test_pid, {:tracker_update_comment_called, issue_id, comment_id, body})
          :ok
        end
      )

    transition_response =
      DynamicTool.execute(
        "tracker_transition_issue",
        %{"issueId" => "SYM-6", "state" => "진행 중"},
        tracker_kind: "jira",
        tracker_transitioner: fn issue_id, state ->
          send(test_pid, {:tracker_transition_called, issue_id, state})
          :ok
        end
      )

    assert_received {:tracker_list_comments_called, "SYM-6"}
    assert_received {:tracker_comment_called, "SYM-6", "## Codex Workpad\n\n- [ ] Start"}
    assert_received {:tracker_update_comment_called, "SYM-6", "11381", "## Codex Workpad\n\n- [x] Start"}
    assert_received {:tracker_transition_called, "SYM-6", "진행 중"}
    assert list_response["success"] == true
    assert Jason.decode!(list_response["output"])["comments"] == [%{"body" => "## Codex Workpad", "id" => "11381"}]
    assert comment_response["success"] == true
    assert update_response["success"] == true
    assert transition_response["success"] == true
  end

  test "tracker comment writes require workspace diff unless they record a runtime blocker" do
    workspace = Path.join(System.tmp_dir!(), "dynamic-tool-no-diff-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    assert {_output, 0} = System.cmd("git", ["init", "-q", workspace], stderr_to_stdout: true)

    test_pid = self()

    clean_response =
      DynamicTool.execute(
        "tracker_update_comment",
        %{"issueId" => "SYM-11", "commentId" => "11388", "body" => "## Codex Workpad\n\n- [x] Planned only"},
        tracker_kind: "jira",
        workspace: workspace,
        require_workspace_diff_for_tracker_comments: true,
        tracker_comment_updater: fn issue_id, comment_id, body ->
          send(test_pid, {:unexpected_tracker_update, issue_id, comment_id, body})
          :ok
        end
      )

    assert clean_response["success"] == false
    assert Jason.decode!(clean_response["output"])["error"]["message"] =~ "blocked until the workspace"
    refute_received {:unexpected_tracker_update, _, _, _}

    blocker_response =
      DynamicTool.execute(
        "tracker_update_comment",
        %{"issueId" => "SYM-11", "commentId" => "11388", "body" => "### Runtime Blocker\n\nNo safe first edit exists."},
        tracker_kind: "jira",
        workspace: workspace,
        require_workspace_diff_for_tracker_comments: true,
        tracker_comment_updater: fn issue_id, comment_id, body ->
          send(test_pid, {:tracker_update, issue_id, comment_id, body})
          :ok
        end
      )

    assert blocker_response["success"] == true
    assert_received {:tracker_update, "SYM-11", "11388", "### Runtime Blocker\n\nNo safe first edit exists."}

    evidence_path = Path.join([workspace, "docs", "codex-squad-evidence.md"])
    File.mkdir_p!(Path.dirname(evidence_path))
    File.write!(evidence_path, "# Codex squad evidence\n")

    diff_response =
      DynamicTool.execute(
        "tracker_add_comment",
        %{"issueId" => "SYM-11", "body" => "## Codex Workpad\n\n- [x] Evidence file created"},
        tracker_kind: "jira",
        workspace: workspace,
        require_workspace_diff_for_tracker_comments: true,
        tracker_commenter: fn issue_id, body ->
          send(test_pid, {:tracker_comment, issue_id, body})
          :ok
        end
      )

    assert diff_response["success"] == true
    assert_received {:tracker_comment, "SYM-11", "## Codex Workpad\n\n- [x] Evidence file created"}
  end

  test "tracker comment writes remain blocked when workspace status cannot be checked" do
    workspace = Path.join(System.tmp_dir!(), "dynamic-tool-no-diff-unknown-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    test_pid = self()

    response =
      DynamicTool.execute(
        "tracker_update_comment",
        %{"issueId" => "SYM-11", "commentId" => "11388", "body" => "## Codex Workpad\n\n- [x] Planned only"},
        tracker_kind: "jira",
        workspace: workspace,
        require_workspace_diff_for_tracker_comments: true,
        tracker_comment_updater: fn issue_id, comment_id, body ->
          send(test_pid, {:unexpected_tracker_update, issue_id, comment_id, body})
          :ok
        end
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "blocked until the workspace has"
    refute_received {:unexpected_tracker_update, _, _, _}
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["linear_graphql"]
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  test "linear_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]
  end

  test "linear_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        "  query Viewer { viewer { id } }  ",
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql ignores legacy operationName arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_789"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql passes multi-operation documents through unchanged" do
    test_pid = self()

    query = """
    query Viewer { viewer { id } }
    query Teams { teams { nodes { id } } }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        linear_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded_query, variables, opts})
          {:ok, %{"errors" => [%{"message" => "Must provide operation name if query contains multiple operations."}]}}
        end
      )

    assert_received {:linear_client_called, forwarded_query, %{}, []}
    assert forwarded_query == String.trim(query)
    assert response["success"] == false
  end

  test "linear_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("linear_graphql", "   ")

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "linear_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "linear_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "linear_graphql validates required arguments before calling Linear" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "   "},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "linear_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        [:not, :valid],
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "linear_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "linear_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :missing_linear_api_token} end
      )

    assert missing_token["success"] == false

    assert Jason.decode!(missing_token["output"]) == %{
             "error" => %{
               "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
             }
           }

    status_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_status, 503}} end
      )

    assert Jason.decode!(status_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    request_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_request, :timeout}} end
      )

    assert Jason.decode!(request_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "linear_graphql falls back to inspect for non-JSON payloads" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true
    assert response["output"] == ":ok"
  end
end
