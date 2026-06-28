# Squad Evidence Continuation

## Background

Live SYM-35 showed that a squad run can finish a Codex role sequence with useful
workspace changes but fail the final evidence gate because verifier rows are
missing or still marked `FAIL`. Symphony currently treats that as a hard runtime
blocker, which leaves the ticket stuck even though the correct next step is to
continue the squad loop from the preserved workspace.

## Scope

- Include: classify `squad evidence contract failed` runtime blockers as
  retryable squad verification continuations while the issue remains active.
- Include: keep true external blockers such as missing auth, input requests, and
  token/no-diff stops as blocked states.
- Include: bound evidence-continuation retries so an endlessly failing evidence
  loop eventually becomes an explicit blocker.
- Include: keep the existing strict `squad.check` completion gate before publish
  handoff.
- Exclude: changing the evidence markdown contract or accepting `FAIL` rows as
  completion.
- Exclude: adding a new queue backend or changing tracker transitions.

## Acceptance Criteria

- [ ] A squad evidence contract failure from a completed Codex role schedules a
      retry instead of entering `blocked` immediately.
- [ ] The retry preserves issue identifier, URL, worker host, and workspace path
      for continuation.
- [ ] After the bounded retry allowance is exhausted, the same failure becomes a
      normal runtime blocker with a workpad blocker marker.
- [ ] Non-evidence runtime blockers still block immediately.

## Validation

- [ ] Add targeted orchestrator regression tests for retry and exhausted retry.
- [ ] Run the focused orchestrator/core tests.
- [ ] Run formatting and diff whitespace checks.

## Decision Notes

- AD-implicit: evidence failures are treated as model/verification progress
  failures, not operator blockers, until retries are exhausted. The escape hatch
  is the bounded retry limit, which preserves the existing visible blocker path
  if the loop cannot converge.
