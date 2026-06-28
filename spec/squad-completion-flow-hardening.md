# Squad Completion Flow Hardening Spec

Date: 2026-06-28
Status: Draft
Slug: `squad-completion-flow-hardening`

## Background

Live SYM e2e runs exposed completion-flow gaps after the Codex squad roles began producing real
branches and PRs. SYM-33 showed a final-verifier green-check loop: after PR checks were green, the
final verifier recorded that volatile status in repository evidence, created a new head, and
retriggered CI. SYM-35 then showed another hardening gap: verifier failure details existed in the
workspace evidence, but the operator-facing blocker only reported the missing required PASS rows.

The repo contract read before this spec:

- `SPEC.md` says Symphony is the scheduler/runner, while ticket writes and PR behavior normally live
  in workflow prompt and agent tooling.
- `elixir/AGENTS.md` requires orchestrator changes to preserve retry, reconciliation, and cleanup
  semantics, and behavior/config changes to update `WORKFLOW.md` and Elixir docs when practical.
- `elixir/docs/codex-squad-symphony-spec.md` already records that failure/recovery hardening must
  define verifier FAIL, final-verifier FAIL, transition failure, and Compose restart behavior.

## Scope

### Included

- Make squad normal completion invoke the `after_complete` publish hook deterministically before the
  issue is considered locally completed/released.
- Ensure publish-hook failure is visible as a runtime blocker instead of being silently ignored when
  it prevents a required branch/PR handoff.
- Align the SYM Jira handoff instruction with available success transitions instead of the legacy
  unavailable `Human Review` target.
- Align workflow branch-sync instructions with the configured PR base (`dev` by default) instead of
  hard-coding `origin/main`.
- Add a hard guard against post-green evidence-only commits that would retrigger PR checks.
- Surface verifier/final-verifier FAIL reasons in the blocker message when `squad.check` fails.

### Excluded

- Implementing or redesigning Cloudflare MCP credential preflight itself.
- Changing the core tracker abstraction into a full workflow engine.
- Adding a persistent database for completed issue memory.
- Reworking all `workspace.publish_pr` staging semantics beyond the post-green/evidence-only guard.
- Merging or landing existing live PRs.

## Acceptance Criteria

### AC-1: Squad completion publish hook is deterministic

When `agent.squad_enabled` is true and a worker exits normally after successful squad evidence
validation, the orchestrator MUST run `hooks.after_complete` exactly once for that workspace before
the issue is locally completed/released.

Validation:

- A unit test simulates a normal squad worker `:DOWN` with a workspace path and asserts the
  after-complete hook side effect occurs.
- A unit test covers hook failure and asserts the issue becomes blocked with a publish/handoff
  runtime-blocker message and the workspace path remains available for operator recovery.

### AC-2: Jira success handoff target is actually reachable

The default SYM workflow MUST no longer instruct agents to move successful work to an unavailable
`Human Review` state. It MUST instruct successful handoff through an available success terminal
transition, using Jira adapter generic success preference (`Done`/`resolved` style targets resolve
to `해결됨` or other configured success states before cancel states).

Validation:

- Workflow prompt/config test asserts the successful handoff instruction uses a success terminal
  target and no longer contains the stale `Human Review` success path.
- Jira adapter tests continue to prove generic success targets prefer `해결됨`/`완료` over `취소`.

### AC-3: Branch sync follows PR base

The SYM workflow MUST instruct agents to sync against the configured PR base branch, defaulting to
`dev`, instead of hard-coding `origin/main` while the publish hook opens PRs against `dev`.

Validation:

- Workflow prompt/config test asserts the branch-sync instruction mentions
  `SYMPHONY_PR_BASE:-dev` or an equivalent configured PR base reference.
- The workflow text no longer requires `git merge origin/main` for the default e2e lane.

### AC-4: Post-green evidence-only commits are blocked

If an open PR already exists for the current branch, its head matches local `HEAD`, and all required
checks for that head are green, `workspace.publish_pr` MUST NOT create another commit/push when the
only pending workspace change is `docs/codex-squad-evidence.md` evidence appended after the green
state. It MUST leave the workspace dirty and report that the PR is already frozen for handoff.

Validation:

- A Mix task test stubs GitHub/gh responses for an existing open PR with green checks and asserts no
  `git add`, `git commit`, or `git push` command is issued for evidence-only changes.
- A negative test asserts substantive non-evidence changes still commit and push.

### AC-5: Evidence-gate blockers expose the actionable verifier reason

When squad evidence validation fails because required verifier PASS rows are missing and the
evidence contains one or more `FAIL` rows, the runtime blocker message MUST include the first
sanitized FAIL reason in addition to the mechanical missing-PASS errors.

Validation:

- A unit test creates evidence with a verifier `FAIL` row and asserts the blocker message contains
  the FAIL reason without raw logs or secrets.
- Existing `squad.check` tests continue to fail missing PASS rows.

## Adversarial Review

- Ambiguous done condition: "agent stopped" is not done; completion requires branch/PR handoff or a
  visible blocker.
- Missing boundary: MCP preflight behavior is deliberately excluded, but its verifier failure must
  be visible so operators can route that fix.
- Over-broad publish guard risk: evidence-only green freeze must not suppress real code/docs/test
  fixes after review feedback.
- Restart risk: local `completed` memory remains process-local; this spec mitigates by pushing Jira
  success handoff toward a terminal state and by making publish failures block visibly.
- Verification risk: live GitHub/Jira checks are networked; deterministic tests must stub those
  boundaries, with live e2e used only as supporting evidence.

## Implementation Notes

- Prefer narrow changes in `SymphonyElixir.Orchestrator`, `SymphonyElixir.AgentRunner`, `WORKFLOW.md`,
  and `Mix.Tasks.Workspace.PublishPr`.
- Keep public `def` additions documented with `@spec` per `elixir/AGENTS.md`.
- Do not log token values, raw provider headers, or raw Codex session payloads.
