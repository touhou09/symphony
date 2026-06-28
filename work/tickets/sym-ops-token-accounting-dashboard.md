## Background
Live SYM-35 made dashboard token totals look much larger than the fresh work in
the latest role because continuation sessions can reread prior evidence, diffs,
and workpad context. The current dashboard total is useful for runaway-cost
visibility, but it is too coarse for diagnosing whether a specific role or retry
is expensive.

## Goal
Separate Symphony token accounting into operator-friendly scopes.

## Scope
- Include: show per-turn token usage.
- Include: show per-role token usage for squad mode.
- Include: show since-resume usage for continuation/retry runs.
- Include: keep issue cumulative usage for cost and runaway monitoring.
- Include: label dashboard/API totals so operators can tell which scope they are
  viewing.
- Exclude: changing provider billing semantics.
- Exclude: hiding cumulative totals.

## Acceptance Criteria
- [ ] `/api/v1/state` exposes issue cumulative, current run, current role, and
      current turn token scopes where available.
- [ ] Dashboard labels distinguish cumulative totals from fresh continuation
      usage.
- [ ] Retry/continuation does not make a resumed role appear as pure new work.
- [ ] Existing token/no-diff guards continue to use the configured cumulative or
      explicitly documented scope.

## Validation
- [ ] Run token accounting unit tests.
- [ ] Run dashboard presenter/render tests.
- [ ] Verify a live continuation run shows separate cumulative and fresh scopes.

## Agent Flow
### CTO (gpt-5.5)
- Define token-scope semantics and guard behavior.

### Implementer (gpt-5.3-codex-spark)
- Implement API/dashboard token-scope fields.

### Verifier (gpt-5.4)
- Validate retry/resume accounting and dashboard labels.

### Final Verifier (gpt-5.5)
- Review operator clarity and residual cost-monitoring risk.

## Handoff Evidence
- PR link, API sample, dashboard screenshot or text snapshot, and token
  accounting test output.
