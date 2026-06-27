defmodule Mix.Tasks.Squad.CheckTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Squad.Check

  setup do
    Mix.Task.reenable("squad.check")
    :ok
  end

  test "validates a squad evidence file with default routing" do
    in_temp_project(fn ->
      File.mkdir_p!("docs")
      File.write!("docs/evidence.md", valid_evidence())

      output = capture_io(fn -> assert :ok = Check.run(["--file", "docs/evidence.md"]) end)

      assert output =~ "squad.check: evidence contract OK"
    end)
  end

  test "raises when evidence is missing a required verifier" do
    in_temp_project(fn ->
      File.mkdir_p!("docs")

      evidence =
        String.replace(
          valid_evidence(),
          "- [x] final_verifier (gpt-5.5): PASS - evidence and scope reviewed.\n",
          ""
        )

      File.write!("docs/evidence.md", evidence)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/squad.check failed with 1 evidence error/, fn ->
            Check.run(["--file", "docs/evidence.md"])
          end
        end)

      assert error_output =~ "final_verifier"
    end)
  end

  test "loads custom verifier routing from workflow" do
    in_temp_project(fn ->
      File.write!("WORKFLOW.md", """
      ---
      agent:
        model_roles:
          cto: gpt-5.5
          implementer: gpt-5.3-codex-spark
          qa: gpt-5.4
          final_verifier: gpt-5.5
        required_verifiers:
          - qa
          - final_verifier
      ---
      Prompt.
      """)

      File.mkdir_p!("docs")

      File.write!("docs/evidence.md", """
      ## Scope

      Custom evidence.

      ## CTO Plan

      - Role: cto
      - Model: gpt-5.5

      ## Implementation

      - Role: implementer
      - Model: gpt-5.3-codex-spark

      ## Verification

      - [x] qa (gpt-5.4): PASS - checked.
      - [x] final_verifier (gpt-5.5): PASS - checked.
      """)

      output =
        capture_io(fn ->
          assert :ok = Check.run(["--file", "docs/evidence.md", "--workflow", "WORKFLOW.md"])
        end)

      assert output =~ "squad.check: evidence contract OK"
    end)
  end

  defp valid_evidence do
    """
    ## Scope

    Implement the requested change inside the Symphony workspace.

    ## CTO Plan

    - Role: cto
    - Model: gpt-5.5
    - Decision: keep implementation scoped and require two verifier passes.

    ## Implementation

    - Role: implementer
    - Model: gpt-5.3-codex-spark
    - Result: code and tests updated.

    ## Verification

    - [x] verifier (gpt-5.4): PASS - targeted tests pass.
    - [x] final_verifier (gpt-5.5): PASS - evidence and scope reviewed.
    """
  end

  defp in_temp_project(fun) do
    root = Path.join(System.tmp_dir!(), "squad-check-task-test-#{System.unique_integer([:positive, :monotonic])}")
    original_cwd = File.cwd!()

    File.rm_rf!(root)
    File.mkdir_p!(root)

    try do
      File.cd!(root, fun)
    after
      File.cd!(original_cwd)
      File.rm_rf!(root)
      Application.delete_env(:symphony_elixir, :workflow_file_path)
    end
  end
end
