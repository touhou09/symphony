## Background
Cloudflare MCP failures such as `invalid_token` and `insufficient_scope` currently surface only after Codex starts a turn. Long-running e2e work should detect missing or insufficient external credentials before dispatch or degrade clearly when the tool is optional.

## Goal
Add MCP credential and scope preflight for configured external tools, starting with Cloudflare MCP.

## Scope
- Include: Detect configured MCP servers from sanitized Codex config or an explicit Symphony config section.
- Include: Add a non-secret preflight result for missing token, invalid token, and insufficient scope where the server exposes enough signal.
- Include: Treat required MCP failures as runtime blockers before dispatch.
- Include: Allow optional MCP failures to degrade with an explicit workpad note.
- Exclude: Storing MCP OAuth tokens in Symphony.
- Exclude: Broad support for every MCP provider in the first pass.

## Acceptance Criteria
- [ ] Required Cloudflare MCP auth/scope failures block before wasting a Codex turn.
- [ ] Optional MCP failures do not block unrelated tickets but are visible in dashboard/workpad evidence.
- [ ] Error messages name only server, status class, and required operator action; no tokens are logged.
- [ ] Tests cover missing token, invalid token, insufficient scope, optional degrade, and required blocker behavior.

## Validation
- [ ] Run MCP preflight unit tests.
- [ ] Run app-server runtime blocker tests.
- [ ] Run a live e2e ticket requiring Cloudflare MCP and confirm it either runs or blocks with a precise non-secret reason.

## Agent Flow
### CTO (gpt-5.5)
- Define required vs optional tool policy and status taxonomy.

### Implementer (gpt-5.3-codex-spark)
- Implement Cloudflare MCP preflight and dashboard/workpad propagation.

### Verifier (gpt-5.4)
- Validate no secrets leak and optional tools degrade as designed.

### Final Verifier (gpt-5.5)
- Review live e2e evidence and remaining provider gaps.

## Handoff Evidence
- PR link, test output, live e2e ticket link, and non-secret blocker/degrade evidence.
