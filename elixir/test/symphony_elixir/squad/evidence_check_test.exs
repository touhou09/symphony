defmodule SymphonyElixir.Squad.EvidenceCheckTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Squad.EvidenceCheck

  @valid_evidence """
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

  test "accepts evidence with configured CTO, implementer, and verifier passes" do
    assert :ok = EvidenceCheck.validate(@valid_evidence)
  end

  test "fails when a required verifier pass is missing" do
    evidence = String.replace(@valid_evidence, "- [x] final_verifier (gpt-5.5): PASS - evidence and scope reviewed.\n", "")

    assert {:error, errors} = EvidenceCheck.validate(evidence)
    assert errors == ["## Verification must include PASS for final_verifier (gpt-5.5)"]
  end

  test "uses custom model routing from workflow context" do
    context = %{
      "model_roles" => %{
        "cto" => "gpt-5.5",
        "implementer" => "gpt-5.3-codex-spark",
        "qa" => "gpt-5.4",
        "security" => "gpt-5.5"
      },
      "required_verifiers" => ["qa", "security"]
    }

    evidence = """
    ## Scope

    Custom workflow evidence.

    ## CTO Plan

    - Role: cto
    - Model: gpt-5.5

    ## Implementation

    - Role: implementer
    - Model: gpt-5.3-codex-spark

    ## Verification

    - [x] qa (gpt-5.4): PASS - behavior checked.
    - [x] security (gpt-5.5): PASS - final review checked.
    """

    assert :ok = EvidenceCheck.validate(evidence, context)
  end
end
