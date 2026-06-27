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
end
