defmodule SymphonyElixir.AgentRunnerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRunner

  describe "squad flow handoff gate" do
    test "blocks handoff when verifier does not PASS" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-agent-runner-squad-blocked-#{System.unique_integer([:positive])}"
        )

      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-1200")
      codex_binary = Path.join(test_root, "fake-codex")

      previous_cwd = File.cwd!()

      try do
        File.mkdir_p!(workspace)
        write_squad_workflow!(workflow_root: workspace_root, codex_binary: codex_binary)

        write_fake_codex_script!(codex_binary,
          verifier_verdict: "FAIL",
          final_verifier_verdict: "PASS"
        )

        issue = %Issue{
          id: "issue-1200",
          identifier: "MT-1200",
          title: "Verifier verdict gate",
          description: "Suite should fail handoff when verifier returns fail.",
          state: "In Progress",
          url: "https://example.org/issues/MT-1200",
          labels: ["backend"]
        }

        File.cd!(test_root)

        assert_raise RuntimeError, ~r/:squad_handoff_blocked/, fn ->
          AgentRunner.run(issue)
        end

        evidence = File.read!("docs/codex-squad-evidence.md")
        assert evidence =~ "| Verifier | gpt-5.4 | failed | FAIL |"
        assert evidence =~ "| Final Verifier | gpt-5.5 | passed | PASS |"
      after
        File.cd!(previous_cwd)
        File.rm_rf(test_root)
      end
    end

    test "allows handoff when verifier and final_verifier pass" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-agent-runner-squad-pass-#{System.unique_integer([:positive])}"
        )

      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-1201")
      codex_binary = Path.join(test_root, "fake-codex")
      previous_cwd = File.cwd!()

      try do
        File.mkdir_p!(workspace)
        write_squad_workflow!(workflow_root: workspace_root, codex_binary: codex_binary)

        write_fake_codex_script!(codex_binary,
          verifier_verdict: "PASS",
          final_verifier_verdict: "PASS"
        )

        issue = %Issue{
          id: "issue-1201",
          identifier: "MT-1201",
          title: "Verifier final verifier pass",
          description: "Suite should allow handoff when both roles pass.",
          state: "In Progress",
          url: "https://example.org/issues/MT-1201",
          labels: ["backend"]
        }

        File.cd!(test_root)

        assert :ok = AgentRunner.run(issue)

        evidence = File.read!("docs/codex-squad-evidence.md")
        assert evidence =~ "| Verifier | gpt-5.4 | passed | PASS |"
        assert evidence =~ "| Final Verifier | gpt-5.5 | passed | PASS |"
      after
        File.cd!(previous_cwd)
        File.rm_rf(test_root)
      end
    end
  end

  defp write_fake_codex_script!(codex_binary,
         verifier_verdict: verifier_verdict,
         final_verifier_verdict: final_verifier_verdict
       ) do
    cto_turn_completed =
      Jason.encode!(%{
        "method" => "turn/completed",
        "output" => "cto plan done"
      })

    implementer_turn_completed =
      Jason.encode!(%{
        "method" => "turn/completed",
        "output" => "implementation complete"
      })

    verifier_turn_completed =
      Jason.encode!(%{
        "method" => "turn/completed",
        "result" => %{"verdict" => verifier_verdict}
      })

    final_verifier_turn_completed =
      Jason.encode!(%{
        "method" => "turn/completed",
        "result" => %{"verdict" => final_verifier_verdict}
      })

    File.write!(codex_binary, """
    #!/bin/sh
    count=0

    while IFS= read -r _line; do
      count=$((count + 1))

      case "$count" in
        1)
          printf '%s\\n' '{\"id\":1,\"result\":{}}'
          ;;
        2)
          printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-squad\"}}}'
          ;;
        3)
          printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-cto\"}}}'
          ;;
        4)
          printf '%s\\n' '#{cto_turn_completed}'
          ;;
        5)
          printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-implementer\"}}}'
          ;;
        6)
          printf '%s\\n' '#{implementer_turn_completed}'
          ;;
        7)
          printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-verifier\"}}}'
          ;;
        8)
          printf '%s\\n' '#{verifier_turn_completed}'
          ;;
        9)
          printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-final-verifier\"}}}'
          ;;
        10)
          printf '%s\\n' '#{final_verifier_turn_completed}'
          ;;
        *)
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)
  end

  defp write_squad_workflow!(opts) do
    workspace_root = Keyword.fetch!(opts, :workflow_root)
    codex_binary = Keyword.fetch!(opts, :codex_binary)

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      workspace:
        root: "#{workspace_root}"
      agent:
        max_turns: 20
        model_roles:
          cto: "gpt-5.5"
          implementer: "gpt-5.3-codex-spark"
          verifier: "gpt-5.4"
          final_verifier: "gpt-5.5"
      codex:
        command: "#{codex_binary} app-server"
      ---
      You are an agent for this repository.
      """
    )

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      SymphonyElixir.WorkflowStore.force_reload()
    end
  end
end
