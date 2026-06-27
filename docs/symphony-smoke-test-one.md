# Symphony One-Ticket E2E Smoke

Use this sequence to run exactly one bounded E2E ticket:

1. Prepare workflow and source to the branch that carries required mix tasks and live helpers:

```bash
export SYMPHONY_SOURCE_REF=feat/jira-tracker-adapter
export SYMPHONY_TICKET_IDENTIFIER=SYM-11
```

2. Run a single bounded compose-backed execution for the selected issue:

```bash
cd /path/to/symphony-workspace/symphony
export SYMPHONY_RUN_LIVE_E2E=1
export SYMPHONY_E2E_TARGET_TICKET=$SYMPHONY_TICKET_IDENTIFIER
make e2e
```

3. After completion, capture hard proof:

```bash
cd /path/to/symphony-workspace/symphony/elixir
git status --short
mix squad.check --file docs/codex-squad-evidence.md --workflow WORKFLOW.md
```

4. Handoff bundle:
- `git status --short` must show a non-empty workspace diff when an implementation path was expected.
- If no diff is expected for the bounded run, `mix squad.check` output must contain an explicit blocker trace and reason.
- Include the resulting `LIVE_E2E_RESULT.txt` and `mix squad.check` output in ticket evidence.

This run is the evidence path required for SYM-11-style bounded no-diff validation.
