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
end
