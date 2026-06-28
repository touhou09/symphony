defmodule SymphonyElixir.Ticket.ConfigPreflightTest do
  use SymphonyElixir.TestSupport

  test "ticket preflight is disabled by default" do
    issue = %Issue{id: "10001", identifier: "SYM-10", title: "Loose ticket", state: "Todo", description: nil}

    assert :ok = Orchestrator.preflight_issue_for_dispatch_for_test(issue)
  end

  test "runtime blocker marker prevents redispatch when no-diff guard is enabled" do
    issue_id = "issue-runtime-blocked"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      codex_max_no_diff_tokens: 1
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    Application.put_env(:symphony_elixir, :memory_tracker_comments, [
      %{
        issue_id: issue_id,
        id: "comment-1",
        body: "## Codex Workpad\n\n<!-- symphony-runtime-blocker:no-diff-token-limit -->\n### Runtime Blocker"
      }
    ])

    issue = %Issue{id: issue_id, identifier: "SYM-RUNTIME", title: "Runtime blocked", state: "Todo", description: nil}

    assert {:error, {:runtime_blocker, message}} = Orchestrator.preflight_issue_for_dispatch_for_test(issue)
    assert message =~ "no-diff token limit"
    assert_receive {:memory_tracker_comments_requested, ^issue_id}
  end

  test "runtime blocker marker preserves total-token cause when total guard is enabled" do
    issue_id = "issue-total-token-blocked"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      codex_max_total_tokens: 1
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    Application.put_env(:symphony_elixir, :memory_tracker_comments, [
      %{
        issue_id: issue_id,
        id: "comment-1",
        body: "## Codex Workpad\n\n<!-- symphony-runtime-blocker:total-token-limit -->\n### Runtime Blocker\n\n- Type: total token limit"
      }
    ])

    issue = %Issue{id: issue_id, identifier: "SYM-TOTAL", title: "Runtime total blocked", state: "Todo", description: nil}

    assert {:error, {:runtime_blocker, message}} = Orchestrator.preflight_issue_for_dispatch_for_test(issue)
    assert message =~ "total token limit"
    refute message =~ "no-diff"
    assert_receive {:memory_tracker_comments_requested, ^issue_id}
  end

  test "runtime blocker type line corrects legacy no-diff marker on total-token blockers" do
    issue_id = "issue-legacy-total-token-blocked"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      codex_max_total_tokens: 1
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    Application.put_env(:symphony_elixir, :memory_tracker_comments, [
      %{
        issue_id: issue_id,
        id: "comment-1",
        body: "## Codex Workpad\n\n<!-- symphony-runtime-blocker:no-diff-token-limit -->\n### Runtime Blocker\n\n- Type: total token limit"
      }
    ])

    issue = %Issue{id: issue_id, identifier: "SYM-LEGACY-TOTAL", title: "Legacy total blocked", state: "Todo", description: nil}

    assert {:error, {:runtime_blocker, message}} = Orchestrator.preflight_issue_for_dispatch_for_test(issue)
    assert message =~ "total token limit"
    refute message =~ "no-diff"
    assert_receive {:memory_tracker_comments_requested, ^issue_id}
  end

  test "codex auth preflight blocks dispatch when the configured auth file is missing" do
    missing_auth_path =
      Path.join(System.tmp_dir!(), "symphony-missing-codex-auth-#{System.unique_integer([:positive])}.json")

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_auth_preflight_enabled: true,
      codex_auth_json_path: missing_auth_path
    )

    issue = %Issue{id: "issue-auth-missing", identifier: "SYM-AUTH-MISSING", title: "Needs auth", state: "Todo"}

    assert {:error, {:runtime_blocker, message}} = Orchestrator.preflight_issue_for_dispatch_for_test(issue)
    assert message =~ "codex authentication preflight failed"
    assert message =~ "auth file missing"
    assert message =~ missing_auth_path
  end

  test "codex auth preflight blocks unreadable auth JSON" do
    auth_path = Path.join(System.tmp_dir!(), "symphony-invalid-codex-auth-#{System.unique_integer([:positive])}.json")
    File.write!(auth_path, "{")

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_auth_preflight_enabled: true,
      codex_auth_json_path: auth_path
    )

    issue = %Issue{id: "issue-auth-invalid-json", identifier: "SYM-AUTH-INVALID-JSON", title: "Needs auth", state: "Todo"}

    assert {:error, {:runtime_blocker, message}} = Orchestrator.preflight_issue_for_dispatch_for_test(issue)
    assert message =~ "auth file is not valid JSON"
  end

  test "codex auth preflight blocks unrecognized auth payloads" do
    auth_path = Path.join(System.tmp_dir!(), "symphony-unrecognized-codex-auth-#{System.unique_integer([:positive])}.json")
    File.write!(auth_path, Jason.encode!(%{"auth_mode" => "unknown"}))

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_auth_preflight_enabled: true,
      codex_auth_json_path: auth_path
    )

    issue = %Issue{id: "issue-auth-unrecognized", identifier: "SYM-AUTH-UNRECOGNIZED", title: "Needs auth", state: "Todo"}

    assert {:error, {:runtime_blocker, message}} = Orchestrator.preflight_issue_for_dispatch_for_test(issue)
    assert message =~ "does not contain recognizable Codex credentials"
  end

  test "codex auth preflight accepts API key credentials without refresh timestamps" do
    auth_path = Path.join(System.tmp_dir!(), "symphony-api-key-codex-auth-#{System.unique_integer([:positive])}.json")
    File.write!(auth_path, Jason.encode!(%{"OPENAI_API_KEY" => "test-api-key"}))

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_auth_preflight_enabled: true,
      codex_auth_json_path: auth_path,
      codex_auth_max_age_ms: 1
    )

    issue = %Issue{id: "issue-auth-api-key", identifier: "SYM-AUTH-API-KEY", title: "Has auth", state: "Todo"}

    assert :ok = Orchestrator.preflight_issue_for_dispatch_for_test(issue)
  end

  test "codex auth preflight blocks stale ChatGPT auth refreshes" do
    auth_path = write_codex_auth_json!(last_refresh: DateTime.utc_now() |> DateTime.add(-2, :hour))

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_auth_preflight_enabled: true,
      codex_auth_json_path: auth_path,
      codex_auth_max_age_ms: 3_600_000
    )

    issue = %Issue{id: "issue-auth-stale", identifier: "SYM-AUTH-STALE", title: "Needs fresh auth", state: "Todo"}

    assert {:error, {:runtime_blocker, message}} = Orchestrator.preflight_issue_for_dispatch_for_test(issue)
    assert message =~ "auth refresh is stale"
    assert message =~ "max_age_ms=3600000"
  end

  test "codex auth preflight blocks missing ChatGPT auth refresh timestamps" do
    auth_path = write_codex_auth_json!(last_refresh: nil)

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_auth_preflight_enabled: true,
      codex_auth_json_path: auth_path,
      codex_auth_max_age_ms: 3_600_000
    )

    issue = %Issue{id: "issue-auth-refresh-missing", identifier: "SYM-AUTH-REFRESH-MISSING", title: "Needs refresh", state: "Todo"}

    assert {:error, {:runtime_blocker, message}} = Orchestrator.preflight_issue_for_dispatch_for_test(issue)
    assert message =~ "auth last_refresh is missing"
  end

  test "codex auth preflight blocks invalid ChatGPT auth refresh timestamps" do
    auth_path = write_codex_auth_json!(last_refresh: "not-a-timestamp")

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_auth_preflight_enabled: true,
      codex_auth_json_path: auth_path,
      codex_auth_max_age_ms: 3_600_000
    )

    issue = %Issue{id: "issue-auth-refresh-invalid", identifier: "SYM-AUTH-REFRESH-INVALID", title: "Needs refresh", state: "Todo"}

    assert {:error, {:runtime_blocker, message}} = Orchestrator.preflight_issue_for_dispatch_for_test(issue)
    assert message =~ "auth last_refresh is not a valid timestamp"
  end

  test "codex auth preflight allows stale ChatGPT auth when max age is disabled" do
    auth_path = write_codex_auth_json!(last_refresh: DateTime.utc_now() |> DateTime.add(-2, :hour))

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_auth_preflight_enabled: true,
      codex_auth_json_path: auth_path,
      codex_auth_max_age_ms: 0
    )

    issue = %Issue{id: "issue-auth-stale-allowed", identifier: "SYM-AUTH-STALE-ALLOWED", title: "Allow refresh", state: "Todo"}

    assert :ok = Orchestrator.preflight_issue_for_dispatch_for_test(issue)
  end

  test "codex authentication runtime marker is retryable after auth preflight is healthy" do
    issue_id = "issue-auth-marker-retryable"
    auth_path = write_codex_auth_json!(last_refresh: DateTime.utc_now())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      codex_max_total_tokens: 1,
      codex_auth_preflight_enabled: true,
      codex_auth_json_path: auth_path,
      codex_auth_max_age_ms: 3_600_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    Application.put_env(:symphony_elixir, :memory_tracker_comments, [
      %{
        issue_id: issue_id,
        id: "comment-1",
        body: "## Codex Workpad\n\n<!-- symphony-runtime-blocker:codex-authentication -->\n### Runtime Blocker\n\n- Type: codex authentication"
      }
    ])

    issue = %Issue{id: issue_id, identifier: "SYM-AUTH-RETRY", title: "Auth marker", state: "Todo", description: nil}

    assert :ok = Orchestrator.preflight_issue_for_dispatch_for_test(issue)
    assert_receive {:memory_tracker_comments_requested, ^issue_id}
  end

  test "configured ticket preflight rejects underspecified active issues" do
    write_workflow_file!(Workflow.workflow_file_path(),
      ticket_block_dispatch_on_invalid_ticket: true,
      ticket_required_description_sections: ["Background", "Scope", "Acceptance Criteria", "Validation"],
      ticket_require_acceptance_checkboxes: true,
      ticket_require_validation_checkboxes: true
    )

    issue = %Issue{
      id: "10002",
      identifier: "SYM-11",
      title: "Missing validation",
      state: "Todo",
      description: "## Background\n\nContext only.\n\n## Scope\n\n- Work here."
    }

    assert {:error, errors} = Orchestrator.preflight_issue_for_dispatch_for_test(issue)
    assert "missing section ## Acceptance Criteria" in errors
    assert "missing section ## Validation" in errors
  end

  test "configured ticket preflight accepts structured ticket content" do
    write_workflow_file!(Workflow.workflow_file_path(),
      ticket_block_dispatch_on_invalid_ticket: true,
      ticket_required_description_sections: ["Background", "Scope", "Acceptance Criteria", "Validation"],
      ticket_require_acceptance_checkboxes: true,
      ticket_require_validation_checkboxes: true
    )

    issue = %Issue{
      id: "10003",
      identifier: "SYM-12",
      title: "Structured ticket",
      state: "Todo",
      description: """
      ## Background

      Codex needs stable ticket inputs.

      ## Scope

      - Add preflight checks.

      ## Acceptance Criteria

      - [ ] Invalid tickets do not dispatch.

      ## Validation

      - [ ] Run ticket preflight tests.
      """
    }

    assert :ok = Orchestrator.preflight_issue_for_dispatch_for_test(issue)
  end

  test "preflight blocks when Codex auth is missing" do
    write_workflow_file!(Workflow.workflow_file_path(), codex_max_no_diff_tokens: 0)

    issue = %Issue{
      id: "10004",
      identifier: "SYM-13",
      title: "Missing auth",
      state: "Todo",
      description: nil
    }

    assert {
             :error,
             {:runtime_blocker, "codex auth status: missing"}
           } = Orchestrator.preflight_issue_for_dispatch_for_test(issue, :missing)
  end

  test "preflight blocks when Codex auth is malformed" do
    write_workflow_file!(Workflow.workflow_file_path(), codex_max_no_diff_tokens: 0)

    issue = %Issue{id: "10005", identifier: "SYM-14", title: "Malformed auth", state: "Todo", description: nil}

    assert {
             :error,
             {:runtime_blocker, "codex auth status: malformed"}
           } = Orchestrator.preflight_issue_for_dispatch_for_test(issue, :malformed)
  end

  test "preflight blocks when Codex auth is stale" do
    write_workflow_file!(Workflow.workflow_file_path(), codex_max_no_diff_tokens: 0)

    issue = %Issue{id: "10006", identifier: "SYM-15", title: "Stale auth", state: "Todo", description: nil}

    assert {
             :error,
             {:runtime_blocker, "codex auth status: stale"}
           } = Orchestrator.preflight_issue_for_dispatch_for_test(issue, :stale)
  end

  test "preflight blocks when Codex auth is unauthorized" do
    write_workflow_file!(Workflow.workflow_file_path(), codex_max_no_diff_tokens: 0)

    issue = %Issue{id: "10007", identifier: "SYM-16", title: "Unauthorized auth", state: "Todo", description: nil}

    assert {
             :error,
             {:runtime_blocker, "codex auth status: unauthorized"}
           } = Orchestrator.preflight_issue_for_dispatch_for_test(issue, :unauthorized)
  end

  test "preflight blocks when Codex auth is unknown" do
    write_workflow_file!(Workflow.workflow_file_path(), codex_max_no_diff_tokens: 0)

    issue = %Issue{id: "10008", identifier: "SYM-17", title: "Unknown auth", state: "Todo", description: nil}

    assert {
             :error,
             {:runtime_blocker, "codex auth status: unknown"}
           } = Orchestrator.preflight_issue_for_dispatch_for_test(issue, :unknown)
  end

  defp write_codex_auth_json!(opts) do
    auth_path =
      Path.join(System.tmp_dir!(), "symphony-codex-auth-#{System.unique_integer([:positive])}.json")

    auth =
      %{
        "auth_mode" => "chatgpt",
        "tokens" => %{
          "access_token" => "test-access-token",
          "refresh_token" => "test-refresh-token"
        }
      }
      |> maybe_put_last_refresh(Keyword.get(opts, :last_refresh))

    File.write!(auth_path, Jason.encode!(auth))

    auth_path
  end

  defp maybe_put_last_refresh(auth, %DateTime{} = last_refresh) do
    Map.put(auth, "last_refresh", DateTime.to_iso8601(last_refresh))
  end

  defp maybe_put_last_refresh(auth, last_refresh) when is_binary(last_refresh) do
    Map.put(auth, "last_refresh", last_refresh)
  end

  defp maybe_put_last_refresh(auth, _last_refresh), do: auth
end
