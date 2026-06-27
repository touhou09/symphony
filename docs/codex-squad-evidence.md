# Codex Squad Evidence

## Scope

- Issue: SYM-6 Phase 2: Implement true Codex role orchestration.
- CTO role defines the bounded contract for role artifacts, evidence rendering, `squad.check` gating, and runtime model override limitation handling.
- Implementation is limited to orchestration/model contract, evidence generation, and tests; Symphony UI and production remote worker fleet hardening remain out of scope.
- Existing single-turn behavior must remain compatible when squad orchestration is disabled or when the runtime explicitly reports unsupported per-role execution.

## CTO Plan

- Role/model: `cto` on configured model `gpt-5.5`.
- CTO turn result: `PASS` for planning handoff; implementation remains delegated to the implementer role.
- Runtime boundary: inspect `elixir/lib/symphony_elixir/codex/app_server.ex`, orchestrator flow, and configuration schema to find the smallest supported isolated-role or model override path. If Codex runtime cannot apply configured role models, persist an explicit blocker/limitation artifact and prevent a false-success handoff.
- Role artifact contract: introduce a single squad run representation with four durable role artifacts:
  - `cto`: plan/scope artifact, configured model, status, notes.
  - `implementer`: implementation result artifact, configured model, status, changed files or summary, validation notes.
  - `verifier`: verifier result artifact, configured model, verdict, validation output.
  - `final_verifier`: final verdict artifact, configured model, verdict, residual risk notes.
- Evidence contract: render one markdown handoff artifact that includes `## Scope`, `## CTO Plan`, `## Implementation`, and `## Verification`; the verification section must contain rows/entries for `verifier` and `final_verifier` with their configured model and `PASS`/`FAIL`.
- Handoff gate: success handoff is blocked unless both `verifier` and `final_verifier` have explicit `PASS` evidence. Missing artifacts, missing verdicts, or non-PASS verdicts must fail the gate.
- Compatibility: wire squad orchestration behind the existing config/runtime path so disabled or unsupported squad orchestration falls back to current single-turn behavior without changing existing callers.
- Validation criteria:
  - Add focused unit tests for role artifact creation and evidence rendering.
  - Add a negative test proving missing verifier or final verifier `PASS` blocks success handoff.
  - Generate representative evidence and run `mix squad.check --file docs/codex-squad-evidence.md --workflow WORKFLOW.md`.
  - Run targeted ExUnit coverage for the orchestrator/app-server role flow.
- Bounded implementer direction:
  - Preserve the existing single-turn loop unless all four configured roles are present.
  - Keep role execution sequential and explicit: `cto`, `implementer`, `verifier`, `final_verifier`.
  - Persist evidence after role execution and on role failure so verifier/final verifier can audit partial runs.
  - Record unsupported or failed model override behavior as a runtime limitation instead of reporting success.

### CTO Runtime Decision

- Preferred path: pass the configured role model as a per-turn `model` value in the Codex app-server `turn/start` params, while running each role in sequence as an isolated role prompt within one app-server session.
- Compatibility path: when `agent.model_roles` is absent or incomplete, retain the existing single-turn loop unchanged.
- Handoff gate: a squad run may only report success after both `verifier` and `final_verifier` artifacts record explicit `PASS`; all missing, `FAIL`, or unsupported-runtime outcomes are blockers.

## Implementation

- Role: implementer (gpt-5.3-codex-spark)
- Result: implemented `Mix.Tasks.Squad.Check` and unit tests so generated squad evidence can be validated with `mix squad.check`; added validation checks for required sections and explicit `PASS` gating for verifier/final_verifier rows.
- Files touched:
  - `elixir/lib/mix/tasks/squad.check.ex` (new mix task)
  - `elixir/test/symphony_elixir/squad_check_task_test.exs` (new regression/contract tests)
- Handoff behavior implemented:
  - evidence headings are required and order-validated (`## Scope`, `## CTO Plan`, `## Implementation`, `## Verification`)
  - verification section parsing supports role rows and enforces both `verifier` and `final_verifier` pass-like verdicts.
- Compatibility note:
  - non-PASS outcomes in verifier/final_verifier now block handoff via `Mix.raise`, while existing squad-related non-gating paths remain unchanged.

## Verification

- Verifier note (`gpt-5.4`): inspected the orchestration changes in `agent_runner.ex`, `codex/app_server.ex`, `config/schema.ex`, and the new squad artifact/test files. `mix squad.check --file ../docs/codex-squad-evidence.md --workflow WORKFLOW.md` passes. Focused unit suites `squad_check_task_test.exs`, `squad_run_test.exs`, and `app_server_test.exs` pass. `agent_runner_test.exs` does not complete in this environment and remains a handoff blocker because the role-flow validation is incomplete.

| Role | Model | Status | Verdict |
| --- | --- | --- | --- |
| Verifier | gpt-5.4 | completed | FAIL |
| Final Verifier | gpt-5.5 | in_progress | FAIL |
| Implementer | gpt-5.3-codex-spark | completed | PASS |

### Final Verifier Note

- Role: final_verifier (gpt-5.5)
- Started: 2026-06-27T00:00:00Z
- Initial status: reviewing existing diff, evidence, and validation blocker before declaring PASS.
