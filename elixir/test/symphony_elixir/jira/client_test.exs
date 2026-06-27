defmodule SymphonyElixir.Jira.ClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Jira.Client

  test "default Jira requests use HTTPS proxy env when configured" do
    env = fn
      "HTTPS_PROXY" -> "http://host.docker.internal:18081"
      "NO_PROXY" -> "localhost,127.0.0.1"
      _name -> nil
    end

    options = Client.proxy_connect_options_for_test("https://example.atlassian.net/rest/api/3/search/jql", env)

    assert options[:timeout] == 30_000
    assert options[:proxy] == {:http, "host.docker.internal", 18_081, []}
  end

  test "default Jira requests respect NO_PROXY host matches" do
    env = fn
      "HTTPS_PROXY" -> "http://host.docker.internal:18081"
      "NO_PROXY" -> ".atlassian.net"
      _name -> nil
    end

    options = Client.proxy_connect_options_for_test("https://example.atlassian.net/rest/api/3/search/jql", env)

    assert options == [timeout: 30_000]
  end

  test "candidate search uses jira status ids when configured" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "jira",
      tracker_endpoint: "https://example.atlassian.net",
      tracker_email: "agent@example.com",
      tracker_api_token: "token",
      tracker_project_slug: "SYM",
      tracker_active_states: ["미해결"],
      tracker_active_status_ids: [" 1 ", "1", "10076"]
    )

    request_fun = fn :post, "https://example.atlassian.net/rest/api/3/search/jql", body, _headers ->
      send(self(), {:jql, body["jql"]})
      {:ok, %{status: 200, body: %{"issues" => [], "isLast" => true}}}
    end

    assert {:ok, []} = Client.fetch_candidate_issues(request_fun: request_fun)
    assert_receive {:jql, "project = \"SYM\" AND status IN (1,10076) ORDER BY priority ASC, created ASC"}
  end

  test "terminal state search uses jira status ids when the configured terminal set is requested" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "jira",
      tracker_endpoint: "https://example.atlassian.net",
      tracker_email: "agent@example.com",
      tracker_api_token: "token",
      tracker_project_slug: "SYM",
      tracker_terminal_states: ["완료", "취소"],
      tracker_terminal_status_ids: ["10072", "10074"]
    )

    request_fun = fn :post, "https://example.atlassian.net/rest/api/3/search/jql", body, _headers ->
      send(self(), {:jql, body["jql"]})
      {:ok, %{status: 200, body: %{"issues" => [], "isLast" => true}}}
    end

    assert {:ok, []} = Client.fetch_issues_by_states(["완료", "취소"], request_fun: request_fun)
    assert_receive {:jql, "project = \"SYM\" AND status IN (10072,10074)"}
  end

  test "fetch issue states accepts Jira issue keys" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "jira",
      tracker_endpoint: "https://example.atlassian.net",
      tracker_email: "agent@example.com",
      tracker_api_token: "token",
      tracker_project_slug: "SYM"
    )

    request_fun = fn :post, "https://example.atlassian.net/rest/api/3/search/jql", body, _headers ->
      send(self(), {:jql, body["jql"]})

      {:ok,
       %{
         status: 200,
         body: %{
           "issues" => [
             %{
               "id" => "10652",
               "key" => "SYM-6",
               "fields" => %{
                 "summary" => "Implement true Codex role orchestration",
                 "description" => nil,
                 "status" => %{"name" => "미해결"},
                 "labels" => []
               }
             }
           ],
           "isLast" => true
         }
       }}
    end

    assert {:ok, [issue]} = Client.fetch_issue_states_by_ids(["SYM-6"], request_fun: request_fun)
    assert_receive {:jql, "key IN (\"SYM-6\")"}
    assert issue.id == "10652"
    assert issue.identifier == "SYM-6"
    assert issue.state == "미해결"
  end

  test "list_comments decodes Jira ADF comments" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "jira",
      tracker_endpoint: "https://example.atlassian.net",
      tracker_email: "agent@example.com",
      tracker_api_token: "token",
      tracker_project_slug: "SYM"
    )

    request_fun = fn :get, "https://example.atlassian.net/rest/api/3/issue/SYM-6/comment?maxResults=100&orderBy=created", nil, _headers ->
      send(self(), :list_comments_called)

      {:ok,
       %{
         status: 200,
         body: %{
           "comments" => [
             %{
               "id" => "11381",
               "created" => "2026-06-27T01:02:03.000+0900",
               "updated" => "2026-06-27T01:05:03.000+0900",
               "author" => %{"displayName" => "Codex"},
               "body" => %{
                 "type" => "doc",
                 "version" => 1,
                 "content" => [
                   %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "## Codex Workpad"}]},
                   %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "- [ ] Start"}]}
                 ]
               }
             }
           ]
         }
       }}
    end

    assert {:ok, [comment]} = Client.list_comments("SYM-6", request_fun: request_fun)
    assert_receive :list_comments_called

    assert comment == %{
             "id" => "11381",
             "body" => "## Codex Workpad\n- [ ] Start",
             "created_at" => "2026-06-27T01:02:03.000+0900",
             "updated_at" => "2026-06-27T01:05:03.000+0900",
             "author" => "Codex"
           }
  end

  test "update_comment sends replacement text as Jira ADF" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "jira",
      tracker_endpoint: "https://example.atlassian.net",
      tracker_email: "agent@example.com",
      tracker_api_token: "token",
      tracker_project_slug: "SYM"
    )

    request_fun = fn :put, "https://example.atlassian.net/rest/api/3/issue/SYM-6/comment/11381", body, _headers ->
      send(self(), {:update_comment_body, body})
      {:ok, %{status: 200, body: %{"id" => "11381"}}}
    end

    assert {:ok, %{"id" => "11381"}} =
             Client.update_comment("SYM-6", "11381", "line one\nline two", request_fun: request_fun)

    assert_receive {:update_comment_body,
                    %{
                      "body" => %{
                        "type" => "doc",
                        "version" => 1,
                        "content" => [
                          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "line one"}]},
                          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "line two"}]}
                        ]
                      }
                    }}
  end
end
