defmodule SymphonyElixir.SquadRunTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.SquadRun

  describe "role artifact creation" do
    test "creates one artifact per role with unrun defaults" do
      issue = %Issue{id: "issue-1", identifier: "MT-1001", title: "Role contract"}
      run = SquadRun.new(issue)

      assert %SquadRun{
               issue_identifier: "MT-1001",
               issue_title: "Role contract"
             } = run

      Enum.each(SquadRun.roles(), fn role ->
        artifact = run.role_artifacts[role]

        assert artifact.role == role
        assert artifact.status == :not_run
        assert artifact.verdict == :inconclusive
      end)
    end
  end

  describe "completion recording" do
    test "records verdict for verifier roles and infers completion status" do
      run =
        SquadRun.new(%{identifier: "MT-1002", title: "Verifier evidence"})
        |> SquadRun.put_completion(:verifier, "gpt-5.4", %{
          "result" => %{"verdict" => "PASS"}
        })
        |> SquadRun.put_completion(:final_verifier, "gpt-5.5", %{
          "result" => %{"verdict" => "FAIL"}
        })

      verifier = run.role_artifacts[:verifier]
      final_verifier = run.role_artifacts[:final_verifier]

      assert verifier.status == :passed
      assert verifier.verdict == :pass
      assert final_verifier.status == :failed
      assert final_verifier.verdict == :fail
      refute SquadRun.handoff_allowed?(run)
    end
  end

  describe "evidence rendering" do
    test "renders sections required by squad handoff checks" do
      run =
        SquadRun.new(%{identifier: "MT-1003", title: "Evidence rendering"})
        |> SquadRun.put_completion(:cto, "gpt-5.5", %{"output" => "plan"})
        |> SquadRun.put_completion(:implementer, "gpt-5.3-codex-spark", %{"output" => "impl"})
        |> SquadRun.put_completion(:verifier, "gpt-5.4", %{"result" => %{"verdict" => "PASS"}})
        |> SquadRun.put_completion(:final_verifier, "gpt-5.5", %{"result" => %{"verdict" => "PASS"}})

      markdown = SquadRun.render_markdown(run)

      assert markdown =~ "## Scope"
      assert markdown =~ "## CTO Plan"
      assert markdown =~ "## Implementation"
      assert markdown =~ "## Verification"
      assert markdown =~ "CTO"
      assert markdown =~ "Implementer"
      assert markdown =~ "| Verifier | gpt-5.4 | passed | PASS |"
      assert markdown =~ "| Final Verifier | gpt-5.5 | passed | PASS |"
    end
  end
end
