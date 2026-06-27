# Symphony One-Ticket E2E Smoke

Use this path when running only a selected bounded `SYM-*` ticket.

1. Add a narrow label set on the target ticket (for example `symphony-e2e` plus a fix-specific label).
2. Copy `elixir/WORKFLOW.md` to a temporary workflow file, then set:
   - `tracker.required_labels` to only the selected label(s),
   - `codex.max_no_diff_tokens` to a low value for bounded smoke (for example `100`),
   - `agent.max_turns` to a bounded value (`6` or `8`) so work does not loop indefinitely.
3. Start Compose using the temporary workflow file mounted at `/app/elixir/WORKFLOW.md`.
4. Wait for candidate selection and verify logs show exactly one active `In Progress` issue before token output begins.
5. On completion, capture:
   - Jira issue final state and comments,
   - `git status --short` from the issue workspace,
   - `mix squad.check --file docs/codex-squad-evidence.md --workflow WORKFLOW.md`.
6. If the evidence includes a runtime blocker row before implementation diff, stop and fix the blocker path before rerunning.

Notes:

- This run intentionally avoids broad dispatch against all active SYM statuses.
- The one-ticket path should be used for bounded implementation verification to prevent token burn on unrelated candidates.
