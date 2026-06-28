## Background
Codex 401 failures happen when the mounted `auth.json` is missing, malformed, stale, or revoked. The new dispatch preflight blocks stale auth before wasting work, but Symphony still lacks a first-class auth keeper and clear operator recovery flow.

## Goal
Add Codex auth keeper behavior that monitors auth freshness, exposes actionable status, and gives operators a safe recovery path for long-running deployments.

## Scope
- Include: Surface Codex auth status in the observability API and dashboard without token values.
- Include: Detect missing, malformed, stale, and revoked auth states as distinct non-secret statuses.
- Include: Add an operator runbook entry for refreshing host Codex login and restarting the orchestrator.
- Include: If supported by Codex app-server, handle or explicitly reject auth refresh requests in a non-spinning way.
- Exclude: Storing OpenAI credentials in Symphony.
- Exclude: Automating interactive browser login.

## Acceptance Criteria
- [ ] Dashboard shows `codex_auth=ok|missing|malformed|stale|unauthorized|unknown` without secrets.
- [ ] Auth failure prevents new dispatches but does not burn tokens or retry in a tight loop.
- [ ] After a successful auth refresh, old codex-authentication blockers do not permanently prevent redispatch.
- [ ] Operator runbook explains exact non-secret steps and verification commands.

## Validation
- [ ] Run auth preflight tests and dashboard presenter tests.
- [ ] Simulate stale auth and confirm dispatch blocks before starting Codex.
- [ ] Refresh auth in the live environment and confirm a formerly auth-blocked test ticket can dispatch again.

## Agent Flow
### CTO (gpt-5.5)
- Decide status taxonomy and recovery flow.

### Implementer (gpt-5.3-codex-spark)
- Add auth status plumbing and runbook updates.

### Verifier (gpt-5.4)
- Check no secret values appear in logs, dashboard payloads, or comments.

### Final Verifier (gpt-5.5)
- Review live e2e evidence and operator usability.

## Handoff Evidence
- PR link, dashboard screenshot or API payload summary, test output, and live e2e blocker/unblock evidence.
