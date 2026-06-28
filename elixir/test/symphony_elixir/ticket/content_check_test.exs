defmodule SymphonyElixir.Ticket.ContentCheckTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Ticket.ContentCheck

  @valid_ticket """
  ## Background

  Current dispatch can start from tickets with underspecified requirements.

  ## Goal

  Block unattended execution until the ticket carries enough planning and validation detail.

  ## Scope

  - Include ticket body validation.
  - Exclude real model spawning.

  ## Acceptance Criteria

  - [ ] Missing required sections fail preflight.
  - [ ] Valid tickets pass preflight.

  ## Validation

  - [ ] Run targeted tests.
  """

  test "accepts a ticket body with required sections and checklists" do
    assert :ok =
             ContentCheck.validate(@valid_ticket,
               required_sections: ContentCheck.default_required_sections(),
               require_acceptance_checkboxes: true,
               require_validation_checkboxes: true
             )
  end

  test "accepts validation aliases used by Jira tickets" do
    ticket = String.replace(@valid_ticket, "## Validation", "## Test Plan")

    assert :ok =
             ContentCheck.validate(ticket,
               required_sections: ["Background", "Scope", "Acceptance Criteria", "Validation"],
               require_validation_checkboxes: true
             )
  end

  test "accepts portal descriptions where markdown headings are collapsed onto one line" do
    ticket =
      "## BackgroundRunner disk was exhausted." <>
        "## Scope- Include local Docker runner headroom." <>
        "## Acceptance Criteria- [ ] Docker has enough free space." <>
        "## Validation- [ ] Run df and docker system df."

    assert :ok =
             ContentCheck.validate(ticket,
               required_sections: ContentCheck.default_required_sections(),
               require_acceptance_checkboxes: true,
               require_validation_checkboxes: true
             )
  end

  test "accepts Jira portal descriptions with bare section headings and checkboxes" do
    ticket = """
    Background

    Runner disk was exhausted.

    Scope

    Include:

    Increase the Docker VM allocation.

    Acceptance Criteria

    [ ] Docker has enough free space.

    Validation

    [ ] Run df and docker system df.
    """

    assert :ok =
             ContentCheck.validate(ticket,
               required_sections: ContentCheck.default_required_sections(),
               require_acceptance_checkboxes: true,
               require_validation_checkboxes: true
             )
  end

  test "reports missing description and sections" do
    assert {:error, errors} =
             ContentCheck.validate(nil,
               required_sections: ["Background", "Acceptance Criteria", "Validation"],
               require_acceptance_checkboxes: true
             )

    assert "ticket description is required" in errors
    assert "missing section ## Background" in errors
    assert "missing section ## Acceptance Criteria" in errors
    assert "missing section ## Validation" in errors
  end

  test "requires checklist items when configured" do
    ticket = String.replace(@valid_ticket, ~r/- \[ \] Missing required sections fail preflight\.\n- \[ \] Valid tickets pass preflight\./, "Acceptance is prose only.")

    assert {:error, errors} =
             ContentCheck.validate(ticket,
               required_sections: ContentCheck.default_required_sections(),
               require_acceptance_checkboxes: true
             )

    assert errors == ["section ## Acceptance Criteria must include checklist items"]
  end

  test "validates a normalized issue and formats blocker comments" do
    issue = %Issue{id: "10001", identifier: "SYM-9", description: "## Background\n\nOnly context."}

    assert {:error, errors} = ContentCheck.validate_issue(issue, required_sections: ["Background", "Validation"])

    comment = ContentCheck.blocker_comment(issue, errors)
    assert comment =~ "Symphony Ticket Preflight Blocker"
    assert comment =~ "SYM-9"
    assert comment =~ "missing section ## Validation"
  end

  test "is disabled when no rules are configured" do
    refute ContentCheck.enabled?(required_sections: [], require_acceptance_checkboxes: false)
    assert ContentCheck.enabled?(required_sections: ["Background"])
    assert ContentCheck.enabled?(require_validation_checkboxes: true)
  end

  test "accepts long valid bodies under a bounded validation time" do
    long_ticket = long_ticket(with_validation_checklist: true)

    {elapsed, status} =
      :timer.tc(fn ->
        ContentCheck.validate(long_ticket,
          required_sections: ContentCheck.default_required_sections(),
          require_acceptance_checkboxes: true,
          require_validation_checkboxes: true
        )
      end)

    assert status == :ok
    assert elapsed <= 2_000_000
  end

  test "flags long malformed bodies with clear errors under a bounded time" do
    malformed = long_ticket(with_validation_checklist: false)

    {elapsed, {:error, errors}} =
      :timer.tc(fn ->
        ContentCheck.validate(malformed,
          required_sections: ContentCheck.default_required_sections(),
          require_acceptance_checkboxes: true,
          require_validation_checkboxes: true
        )
      end)

    assert elapsed <= 2_000_000
    assert errors == ["section ## Validation must include checklist items"]
  end

  test "does not regress on long malformed body runtime" do
    malformed = long_ticket(with_validation_checklist: false)

    {elapsed, status} =
      :timer.tc(fn ->
        assert {:error, _} =
                 ContentCheck.validate(malformed,
                   required_sections: ContentCheck.default_required_sections(),
                   require_acceptance_checkboxes: true,
                   require_validation_checkboxes: true
                 )
      end)

    assert elapsed <= 2_000_000
    assert {:error, _} = status
  end

  test "rejects invalid validation timeout configuration" do
    assert {:error, ["validation_timeout_ms must be a positive integer"]} =
             ContentCheck.validate(@valid_ticket,
               required_sections: ContentCheck.default_required_sections(),
               validation_timeout_ms: 0
             )

    assert {:error, ["validation_timeout_ms must be a positive integer"]} =
             ContentCheck.validate(@valid_ticket,
               required_sections: ContentCheck.default_required_sections(),
               validation_timeout_ms: 1.5
             )
  end

  defp long_ticket(opts) do
    payload = Keyword.get(opts, :payload, String.duplicate("x", 90_000))

    validation_section =
      if opts[:with_validation_checklist] do
        "## Validation\n\n- [ ] Run parser stability check.\n"
      else
        "## Validation\n\nParser stability check needs prose only.\n"
      end

    """
    ## Background

    #{payload}

    ## Scope

    - Stress parser and section extraction with long, sanitized bodies.

    ## Acceptance Criteria

    - [ ] long bodies validate quickly.
    - [ ] malformed long bodies fail with actionable errors.

    #{validation_section}
    """
  end
end
