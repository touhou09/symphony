defmodule Mix.Tasks.SquadCheckTaskTest do
  use SymphonyElixir.TestSupport

  alias Mix.Tasks.Squad.Check

  @valid_evidence """
  ## Scope
  - Issue: MT-TEST-1

  ## CTO Plan
  - Plan for CTO role.

  ## Implementation
  - Role implementations.

  ## Verification
  | Role | Model | Status | Verdict |
  | --- | --- | --- | --- |
  | Verifier | gpt-5.4 | passed | PASS |
  | Final Verifier | gpt-5.5 | passed | PASS |
  """

  @final_verifier_fail """
  ## Scope
  - Issue: MT-TEST-2

  ## CTO Plan
  - Plan for CTO role.

  ## Implementation
  - Role implementations.

  ## Verification
  | Role | Model | Status | Verdict |
  | --- | --- | --- | --- |
  | Verifier | gpt-5.4 | passed | PASS |
  | Final Verifier | gpt-5.5 | failed | FAIL |
  """

  @missing_section """
  ## Scope
  - Issue: MT-TEST-3

  ## CTO Plan
  - Plan for CTO role.

  ## Implementation
  - Role implementations.
  """

  test "passes for valid evidence with PASS verifier and final_verifier rows" do
    workspace_root = Path.join(System.tmp_dir!(), "symphony-elixir-squad-check-pass-#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(workspace_root)
      evidence_file = Path.join(workspace_root, "symphony-squad-evidence-pass.md")
      workflow_file = Path.join(workspace_root, "WORKFLOW.md")

      File.write!(evidence_file, @valid_evidence)
      write_workflow_file!(workflow_file)

      assert :ok = Check.run(["--file", evidence_file, "--workflow", workflow_file])
    after
      File.rm_rf(workspace_root)
    end
  end

  test "fails when verifier or final_verifier did not PASS" do
    workspace_root = Path.join(System.tmp_dir!(), "symphony-elixir-squad-check-fail-#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(workspace_root)
      evidence_file = Path.join(workspace_root, "symphony-squad-evidence-fail.md")
      workflow_file = Path.join(workspace_root, "WORKFLOW.md")

      File.write!(evidence_file, @final_verifier_fail)
      write_workflow_file!(workflow_file)

      assert_raise Mix.Error, ~r/final_verifier.*PASS/, fn ->
        Check.run(["--file", evidence_file, "--workflow", workflow_file])
      end
    after
      File.rm_rf(workspace_root)
    end
  end

  test "fails when required sections are missing" do
    workspace_root = Path.join(System.tmp_dir!(), "symphony-elixir-squad-check-missing-#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(workspace_root)
      evidence_file = Path.join(workspace_root, "symphony-squad-evidence-missing.md")
      workflow_file = Path.join(workspace_root, "WORKFLOW.md")

      File.write!(evidence_file, @missing_section)
      write_workflow_file!(workflow_file)

      assert_raise Mix.Error, ~r/Missing required squad sections/, fn ->
        Check.run(["--file", evidence_file, "--workflow", workflow_file])
      end
    after
      File.rm_rf(workspace_root)
    end
  end
end
