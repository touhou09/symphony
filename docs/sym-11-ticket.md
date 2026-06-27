## Background

The live E2E run dispatched SYM-6 and split tickets SYM-7 through SYM-10, but every worker exceeded `codex.max_no_diff_tokens` with no workspace git changes. Symphony can poll, dispatch, start Codex, stream token accounting, and block no-diff runs, but it still failed to drive agents into concrete code changes for bounded tickets.

## Scope

- Include: investigate why role prompts/workflow instructions lead to analysis/workpad activity without repository changes.
- Include: adjust prompts, role sequencing, dispatch gating, or runtime checks so implementer turns must either produce a scoped git diff or explicitly block early.
- Include: add a regression test or fake app-server scenario that fails when an implementer run completes without diff/evidence after substantial token use.
- Include: document the expected operator flow for running one bounded E2E ticket at a time.
- Exclude: Symphony UI work.
- Exclude: removing the no-diff guard.
- Exclude: broad implementation of all split tickets in one run.

## Acceptance Criteria

- [ ] A bounded implementation ticket cannot consume high tokens without either creating a non-empty git diff or recording a concrete blocker before the no-diff threshold.
- [ ] Implementer role instructions make the first code/test edit path explicit and verifiable.
- [ ] Symphony has a test or smoke fixture that catches no-diff completion after agent workpad-only behavior.
- [ ] Operator docs explain how to run a single selected SYM ticket for E2E instead of dispatching all active candidates.
- [ ] The fix is validated by rerunning one bounded E2E ticket and capturing either a non-empty git diff or an earlier intentional blocker.

## Validation

- [ ] Run targeted tests for the no-diff/implementer regression path.
- [ ] Run `mix format --check-formatted`.
- [ ] Run `mix ticket.check` for the selected bounded E2E ticket body.
- [ ] Run one-ticket Compose smoke and capture workspace `git status --short` plus `mix squad.check` evidence if a diff is produced.
