## Background
AIDevSquad is resilient because each loop is short, stateless, and re-derives progress from tracker plus git artifacts. Symphony currently keeps Codex as the long-running main runtime per ticket, which makes token limits, auth expiry, and stalled turns more expensive.

## Goal
Add a stateless queue mode for Symphony that runs bounded turns, persists progress evidence, and requeues active tickets instead of depending on one long-lived Codex session.

## Scope
- Include: Add a configuration option for bounded-turn stateless mode.
- Include: Persist enough workspace/workpad evidence for the next run to re-derive the next step.
- Include: Requeue active tickets after each successful bounded turn with backoff and capacity limits.
- Include: Keep the existing long-running mode as the default unless enabled.
- Exclude: Rewriting the tracker integration.
- Exclude: Replacing Codex with another model runtime.

## Acceptance Criteria
- [ ] A ticket can progress across multiple short Codex sessions without losing state.
- [ ] Successful bounded turns release the worker slot and requeue the ticket when still active.
- [ ] Token accounting remains per ticket and cumulative across continuations.
- [ ] The dashboard shows queued, running, blocked, and continuation state clearly.

## Validation
- [ ] Run orchestrator queue and continuation tests.
- [ ] Run a live e2e ticket that intentionally needs more than one turn and verify it resumes from git/workpad evidence.
- [ ] Restart the orchestrator mid-ticket and verify the next poll re-derives the correct state.

## Agent Flow
### CTO (gpt-5.5)
- Define mode boundaries and failure semantics.

### Implementer (gpt-5.3-codex-spark)
- Implement bounded-turn queue behavior behind config.

### Verifier (gpt-5.4)
- Validate restart recovery, queue fairness, and token accounting.

### Final Verifier (gpt-5.5)
- Review e2e evidence and residual risk.

## Handoff Evidence
- PR link, queue/state screenshots or API summaries, test output, and restart e2e notes.
