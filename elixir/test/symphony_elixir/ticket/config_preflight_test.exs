defmodule SymphonyElixir.Ticket.ConfigPreflightTest do
  use SymphonyElixir.TestSupport

  @workflow_prompt "You are an agent for this repository."

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

  test "required Cloudflare MCP missing token in codex config blocks dispatch before runtime" do
    token_key = "SYM35_TEST_MISSING_MCP_TOKEN_#{System.unique_integer([:positive])}"
    previous_token = System.get_env(token_key)

    System.delete_env(token_key)

    codex_config_path = Path.join(System.tmp_dir!(), "symphony-preflight-missing-token-#{System.unique_integer([:positive])}.toml")
    previous_codex_config_path = Application.get_env(:symphony_elixir, :codex_host_config_path)

    write_file!(codex_config_path, """
    [mcp_servers.cloudflare]
    env = { #{token_key} = "${#{token_key}}" }
    """)

    Application.put_env(:symphony_elixir, :codex_host_config_path, codex_config_path)

    try do
      write_workflow_with_mcp_preflight!(%{"cloudflare" => %{"required" => true}})

      assert {:error, {:runtime_blocker, message}} =
               Orchestrator.preflight_issue_for_dispatch_for_test(%Issue{
                 id: "10004",
                 identifier: "SYM-13",
                 title: "Cloudflare token required",
                 state: "Todo",
                 description: "## Background\n\nCloudflare MCP check needed."
               })

      assert message =~ "cloudflare"
      assert message =~ "status=missing_token"
      assert message =~ "configure Cloudflare MCP credentials"
      refute String.contains?(message, token_key)
    after
      if is_binary(previous_token) do
        System.put_env(token_key, previous_token)
      else
        System.delete_env(token_key)
      end

      if previous_codex_config_path == nil do
        Application.delete_env(:symphony_elixir, :codex_host_config_path)
      else
        Application.put_env(:symphony_elixir, :codex_host_config_path, previous_codex_config_path)
      end

      File.rm_rf(codex_config_path)
    end
  end

  test "required Cloudflare MCP invalid token blocks dispatch" do
    write_workflow_with_mcp_preflight!(%{"cloudflare" => %{"required" => true, "status" => "invalid_token"}})

    assert {:error, {:runtime_blocker, message}} =
             Orchestrator.preflight_issue_for_dispatch_for_test(%Issue{
               id: "10005",
               identifier: "SYM-14",
               title: "Cloudflare token invalid",
               state: "Todo",
               description: "## Background\n\nCloudflare MCP check needed."
             })

    assert message =~ "cloudflare"
    assert message =~ "status=invalid_token"
    assert message =~ "rotate/replace Cloudflare MCP token"
  end

  test "required Cloudflare MCP with missing codex host config returns sanitized blocker" do
    previous_codex_config_path = Application.get_env(:symphony_elixir, :codex_host_config_path)
    missing_config_path = Path.join(System.tmp_dir!(), "symphony-preflight-missing-config-#{System.unique_integer([:positive])}.toml")

    File.rm_rf(missing_config_path)
    Application.put_env(:symphony_elixir, :codex_host_config_path, missing_config_path)

    try do
      write_workflow_with_mcp_preflight!(%{"cloudflare" => %{"required" => true}})

      assert {:error, {:runtime_blocker, message}} =
               Orchestrator.preflight_issue_for_dispatch_for_test(%Issue{
                 id: "10008",
                 identifier: "SYM-17",
                 title: "Cloudflare config missing",
                 state: "Todo",
                 description: "## Background\n\nCloudflare MCP config check."
               })

      assert message =~ "cloudflare"
      assert message =~ "status=missing_token"
      assert message =~ "configure Cloudflare MCP credentials"
      refute String.contains?(message, missing_config_path)
    after
      if previous_codex_config_path == nil do
        Application.delete_env(:symphony_elixir, :codex_host_config_path)
      else
        Application.put_env(:symphony_elixir, :codex_host_config_path, previous_codex_config_path)
      end
    end
  end

  test "required Cloudflare MCP with unreadable codex host config returns sanitized blocker" do
    previous_codex_config_path = Application.get_env(:symphony_elixir, :codex_host_config_path)
    codex_config_dir = Path.join(System.tmp_dir!(), "symphony-preflight-missing-config-dir-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(codex_config_dir) end)
    File.mkdir_p!(codex_config_dir)
    Application.put_env(:symphony_elixir, :codex_host_config_path, codex_config_dir)

    try do
      write_workflow_with_mcp_preflight!(%{"cloudflare" => %{"required" => true}})

      assert {:error, {:runtime_blocker, message}} =
               Orchestrator.preflight_issue_for_dispatch_for_test(%Issue{
                 id: "10009",
                 identifier: "SYM-18",
                 title: "Cloudflare unreadable config",
                 state: "Todo",
                 description: "## Background\n\nCloudflare MCP config check."
               })

      assert message =~ "cloudflare"
      assert message =~ "status=missing_token"
      assert message =~ "configure Cloudflare MCP credentials"
    after
      if previous_codex_config_path == nil do
        Application.delete_env(:symphony_elixir, :codex_host_config_path)
      else
        Application.put_env(:symphony_elixir, :codex_host_config_path, previous_codex_config_path)
      end
    end
  end

  test "required Cloudflare MCP insufficient scope blocks dispatch" do
    write_workflow_with_mcp_preflight!(%{"cloudflare" => %{"required" => true, "status" => "insufficient_scope"}})

    assert {:error, {:runtime_blocker, message}} =
             Orchestrator.preflight_issue_for_dispatch_for_test(%Issue{
               id: "10006",
               identifier: "SYM-15",
               title: "Cloudflare scope check",
               state: "Todo",
               description: "## Background\n\nCloudflare MCP scope check."
             })

    assert message =~ "cloudflare"
    assert message =~ "status=insufficient_scope"
    assert message =~ "MCP scopes"
  end

  test "optional Cloudflare MCP failure degrades dispatch with a workpad warning" do
    write_workflow_with_mcp_preflight!(%{"cloudflare" => %{"required" => false, "status" => "invalid_token"}})
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_comments, [])

    issue = %Issue{
      id: "10007",
      identifier: "SYM-16",
      title: "Cloudflare MCP optional warning",
      state: "Todo",
      description: "## Background\n\nCloudflare MCP warning."
    }

    assert :ok = Orchestrator.preflight_issue_for_dispatch_for_test(issue)
    assert_receive {:memory_tracker_comment, "10007", comment_body}
    assert comment_body =~ "symphony-mcp-preflight"
    assert comment_body =~ "cloudflare"
    assert comment_body =~ "status=invalid_token"
    assert comment_body =~ "optional"
  end

  test "Codex-config-only Cloudflare MCP missing token degrades as optional evidence" do
    token_key = "SYM35_TEST_OPTIONAL_MCP_TOKEN_#{System.unique_integer([:positive])}"
    previous_token = System.get_env(token_key)

    System.delete_env(token_key)

    codex_config_path = Path.join(System.tmp_dir!(), "symphony-preflight-optional-token-#{System.unique_integer([:positive])}.toml")
    previous_codex_config_path = Application.get_env(:symphony_elixir, :codex_host_config_path)

    write_file!(codex_config_path, """
    [mcp_servers.cloudflare]
    env = { #{token_key} = "${#{token_key}}" }
    """)

    Application.put_env(:symphony_elixir, :codex_host_config_path, codex_config_path)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_comments, [])

    try do
      write_workflow_with_mcp_preflight!(%{})

      assert :ok =
               Orchestrator.preflight_issue_for_dispatch_for_test(%Issue{
                 id: "10010",
                 identifier: "SYM-19",
                 title: "Cloudflare MCP optional from Codex config",
                 state: "Todo",
                 description: "## Background\n\nCloudflare MCP may be available."
               })

      assert_receive {:memory_tracker_comment, "10010", comment_body}
      assert comment_body =~ "symphony-mcp-preflight"
      assert comment_body =~ "cloudflare"
      assert comment_body =~ "status=missing_token"
      assert comment_body =~ "configure Cloudflare MCP credentials"
      refute String.contains?(comment_body, token_key)
    after
      if is_binary(previous_token) do
        System.put_env(token_key, previous_token)
      else
        System.delete_env(token_key)
      end

      if previous_codex_config_path == nil do
        Application.delete_env(:symphony_elixir, :codex_host_config_path)
      else
        Application.put_env(:symphony_elixir, :codex_host_config_path, previous_codex_config_path)
      end

      File.rm_rf(codex_config_path)
    end
  end

  defp write_workflow_with_mcp_preflight!(cloudflare_mcp_settings) do
    server_config = Map.get(cloudflare_mcp_settings, "cloudflare", %{})
    required = Map.get(server_config, "required") || false
    status = Map.get(server_config, "status")

    preflight_yaml =
      if map_size(cloudflare_mcp_settings) == 0 do
        ""
      else
        status_lines =
          if is_binary(status) do
            ["    status: \"#{status}\""]
          else
            []
          end

        [
          "mcp_preflight:",
          "  cloudflare:",
          "    required: #{required}",
          status_lines
        ]
        |> List.flatten()
        |> Enum.join("\n")
      end

    workflow_root = Path.join(System.tmp_dir!(), "symphony-elixir-preflight")

    content_lines = [
      "---",
      "tracker:",
      "  kind: memory",
      "  endpoint: null",
      "  api_key: null",
      "  project_slug: null",
      "  active_states: [Todo, In Progress]",
      "  terminal_states: [Done]",
      "polling:",
      "  interval_ms: 30000",
      "workspace:",
      "  root: \"#{workflow_root}\"",
      "codex:",
      "  command: \"codex app-server\"",
      "  approval_policy:",
      "    reject:",
      "      sandbox_approval: true",
      "      rules: true",
      "      mcp_elicitations: true",
      "  thread_sandbox: workspace-write",
      "  turn_timeout_ms: 3600000",
      "  read_timeout_ms: 5000",
      "  stall_timeout_ms: 300000",
      "  max_total_tokens: 0",
      "  max_no_diff_tokens: 0"
    ]

    content_lines =
      if preflight_yaml == "" do
        content_lines
      else
        content_lines ++ [preflight_yaml]
      end

    workflow_file = Workflow.workflow_file_path()

    File.write!(workflow_file, Enum.join(content_lines, "\n") <> "\n---\n#{@workflow_prompt}\n")
    WorkflowStore.force_reload()
  end

  defp write_file!(path, contents) do
    File.write!(path, contents)
  end
end
