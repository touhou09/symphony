## 2026-06-28: Pending issue triggered publish hook [done]
- **What**: A live SYM-35 monitor found that moving a ticket to `Pending` could still run the completion publish hook and push the workspace base branch.
- **Why**: Non-active states are blockers or pauses, not successful handoff; publish must only happen after terminal completion or explicit squad success.
- **Impact**: Prevents blocked Jira tickets from creating direct base-branch pushes or false PR handoff attempts.
- **Test**: `mix test` -> 365 passed, 2 skipped; targeted core/publish tests cover non-active no-hook and base-branch publish refusal.
- **Trap**: SYM-35 first looked like an evidence retry issue, but the workpad showed a missing Linear live-e2e auth blocker; inspection then exposed the accidental `dev` publish path.
---
