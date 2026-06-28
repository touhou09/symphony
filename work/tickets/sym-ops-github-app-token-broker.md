## Background
Symphony currently relies on long-lived environment tokens for GitHub publish and PR operations. AIDevSquad is more stable here because it uses a GitHub App installation token minted at runtime instead of depending on a stale personal token.

## Goal
Add a GitHub App token broker path for Symphony publish and GitHub API operations so long-running workers can mint short-lived, repo-scoped tokens on demand.

## Scope
- Include: Support GitHub App credentials from environment variable names or mounted secret paths without logging values.
- Include: Mint installation tokens only when needed and pass them to git/gh/publish code without storing them in repo config.
- Include: Add tests for missing credentials, successful token resolution via a fake HTTP client, and publish fallback behavior.
- Exclude: Creating or rotating the real GitHub App secret values.
- Exclude: Changing branch protection or repository rulesets.

## Acceptance Criteria
- [ ] Symphony can publish PRs with a runtime-minted GitHub App installation token.
- [ ] Existing `GH_TOKEN` / `GITHUB_TOKEN` behavior remains supported as fallback.
- [ ] Token values are never printed, committed, or written into workspace git config.
- [ ] Failure to mint a token becomes a runtime blocker with an explicit non-secret reason.

## Validation
- [ ] Run targeted token broker tests.
- [ ] Run `mix test`.
- [ ] Run a dry-run publish path with fake credentials and confirm no token value appears in logs or `git config`.
- [ ] In live e2e, dispatch one ticket that reaches PR creation using the broker or records a clear blocker if real GitHub App secrets are absent.

## Agent Flow
### CTO (gpt-5.5)
- Define credential boundaries, fallback order, and logging redaction rules.

### Implementer (gpt-5.3-codex-spark)
- Implement the token broker and wire it into publish/PR operations.

### Verifier (gpt-5.4)
- Check tests, logs, git config, and fallback behavior.

### Final Verifier (gpt-5.5)
- Review evidence and residual operational risk.

## Handoff Evidence
- PR link, test output, dry-run log summary, and live e2e ticket comment.
