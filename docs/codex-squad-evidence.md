## Scope

- Add a bounded, deterministic Jira candidate dispatch path so the orchestrator starts no more than the configured number of active issue runs at once.
- Keep eligible candidates waiting in existing priority/created ordering until an active issue releases a slot by reaching terminal, canceled, blocked, or stale-cleaned state.
- Add a conservative local Compose default for the active issue limit and make it configurable without changing role prompts or GitHub PR publication semantics.
- Preserve existing per-ticket role sequencing, completion behavior, stale cleanup, and restart safety: running issues must not be duplicated and terminal/canceled issues must not be redispatched.
- Improve runtime status/log output enough to distinguish running issues from queued/waiting candidates.
- Validate with focused unit tests, an integration-style over-capacity candidate simulation, targeted ExUnit coverage for orchestrator dispatch, `mix format --check-formatted`, and seven-candidate evidence proving the limit prevents seven simultaneous starts.

## CTO Plan
- CTO model reference: gpt-5.5

- Scheduling semantics:
  - Treat an issue as occupying a dispatch slot while it has a non-terminal active run/lease or an in-progress orchestration state that would be unsafe to start again after restart.
  - Candidate ordering must be deterministic and documented. Prefer the repository's existing Jira priority/created ordering; if the existing selector already encodes a richer local rule, preserve that rule and apply the cap after eligibility filtering.
  - Select `available_slots = max_active_issues - currently_active_issues`, clamp below zero to zero, and dispatch only the first `available_slots` eligible waiting candidates.
  - Emit queue state with counts for active, waiting, dispatched, skipped terminal/canceled/stale, and the configured limit.
- Slot release cases:
  - Release a slot when the issue/run reaches successful terminal, canceled terminal, blocked/human-review handoff, or is removed by stale cleanup.
  - Do not release a slot just because the orchestrator process restarts; persisted run/lease state must be consulted first.
  - If an active issue becomes stale and cleanup marks/releases it, it may stop counting only after that cleanup decision is persisted.
- Restart behavior:
  - Rebuild active-slot accounting from persisted issue/run/lease state before selecting new candidates.
  - Exclude terminal, canceled, and stale-cleaned tickets before ordering and cap selection.
  - Never dispatch an issue that already has an active lease/run record, even if it still appears in the Jira candidate query.
- Config:
  - Introduce a small active limit suitable for local Compose by default, with environment/config override and tests covering default and override behavior.
  - Use an explicit validation path for invalid values, falling back conservatively or failing startup according to existing config conventions.
- Implementation boundaries:
  - Keep changes local to candidate selection/dispatch orchestration, config, and observability.
  - Do not change model role prompts, ticket content contracts, PR publication, or currently running SYM-15 through SYM-21.
- Validation criteria for implementer/verifiers:
  - Reproduce current fanout behavior before code edits with a deterministic test or local simulation showing seven eligible candidates can all be selected when uncapped.
  - Add unit coverage for active limit enforcement, deterministic queued ordering, terminal/canceled/stale exclusion, restart no-duplicate behavior, and slot-release accounting.
  - Add or update an integration-style test where seven candidates and a limit below seven start only the limited subset, with the rest reported as waiting.
  - Run targeted ExUnit dispatch tests and `mix format --check-formatted`.
  - Capture before/after evidence in this file showing the seven-candidate queue does not start seven agents with a lower limit.

### CTO Code Landmarks And Risks

- Existing dispatch path: `SymphonyElixir.Orchestrator.maybe_dispatch/1` fetches candidates, checks only `available_slots(state) > 0`, and calls `choose_issues/2`.
- Existing ordering: `sort_issues_for_dispatch/1` sorts by `priority_rank(priority)`, then `created_at`, then identifier/id. Preserve this as the documented deterministic order.
- Existing eligibility guards: `should_dispatch_issue?/5` excludes non-routable, terminal, blocked, claimed, running, in-memory blocked, per-state-over-limit, and worker-over-limit issues.
- Current restart gap: `running`, `claimed`, and `blocked` live in the GenServer state. A Compose restart reconstructs none of those active claims, so Jira candidates that still look active can be selected again and the active-slot count starts at zero.
- Existing config surface: `agent.max_concurrent_agents` currently defaults to `10` in `Config.Schema.Agent`; local Compose needs a lower conservative default or a clearly separate Jira active issue limit if preserving legacy agent concurrency matters.
- Migration risk: lowering `agent.max_concurrent_agents` directly may affect non-Jira/Linear behavior and retry scheduling. Prefer a narrowly named active issue dispatch limit if tests show existing agent concurrency has broader semantics.
- Sync risk: this workspace's remote initially tracked only `origin/dev`; after explicitly fetching `origin/main`, `git merge origin/main` failed with `fatal: refusing to merge unrelated histories`. Do not force an unrelated-history merge without human repository guidance; record this as pull skill evidence and continue from `origin/dev` only if the squad workflow allows it.

### CTO Continuation Review

- 2026-06-27T16:09:46Z `cto` (`gpt-5.5`) resumed retry attempt #1 with the issue still in `진행 중` and a non-empty workspace diff.
- Current scheduling shape remains in scope: the Jira active issue cap is separate from global agent concurrency, defaulted to `3`, and enforced by active-slot accounting over the union of in-memory running entries and persisted running claims.
- Slot-release semantics remain bounded and conservative: successful spawn keeps a persisted claim for restart safety, in-memory `running` prevents duplicate live dispatch, terminal/canceled/blocked/stale paths remove the active slot from current state, and candidate reconciliation removes stale persisted claims when the issue is no longer eligible.
- Before evidence: the pre-change `maybe_dispatch/1` only checked `available_slots(state) > 0`, while `available_slots/1` was based on `agent.max_concurrent_agents` (`10` by default). With seven eligible Jira candidates and no active agents, all seven could be selected in one poll.
- After evidence: `dispatch plan caps active candidates and keeps deterministic ordering with a seven-candidate queue` proves a seven-candidate set with `max_active_issues: 3` dispatches only `["MT-305", "MT-300", "MT-303"]` and leaves `["MT-301", "MT-304", "MT-302", "MT-306"]` queued.
- Restart evidence: `persisted restart claims are renewed and keep their active slot` proves an expired persisted claim is renewed on load and prevents a second candidate from dispatching when the active limit is `1`.
- CTO validation rerun:
  - `mix test test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/orchestrator_status_test.exs` -> pass (`100 tests, 0 failures`)
  - `mix format --check-formatted` -> pass
  - `mix squad.check --file ../docs/codex-squad-evidence.md --workflow WORKFLOW.md` -> fail only because required verifier (`gpt-5.4`) and final_verifier (`gpt-5.5`) PASS rows are not yet present.

## Implementation

- Model: `gpt-5.3-codex-spark`
- Role: implementer
- Scope: bounded active-slot dispatch with deterministic queueing and slot visibility in status output, preserving existing role sequencing.
- First edit path (verified): `elixir/lib/symphony_elixir/orchestrator.ex`
- Result summary:
  - Added `max_active_issues` to runtime state (`orchestrator.ex`) and defaulted it to conservative local Compose value via config (`schema.ex`).
  - Added slot accounting over both `running` and `running_claims` to keep dispatch bounded on active occupancy.
  - Added bounded claim/queue selection flow and terminal/cancelled/stale exclusion remains enforced before dispatch.
  - Updated status snapshot to report `max_active_issues`, `active_issue_slots`, and `active_slots_remaining`.
  - Made snapshot rendering resilient to partial run metadata in older/stale snapshots.
- Result summary (implementer turn #2, retry #1):
  - Added regression coverage for queue refill after slot release in
    `elixir/test/symphony_elixir/workspace_and_config_test.exs`.
  - Added assertions for `dispatch_plan_for_test/2` behavior with a claimed issue occupying slot and a blocked active candidate.
  - Re-ran the targeted dispatch suite and `mix format --check-formatted`.
- Validation already run:
  - `mix test test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/orchestrator_status_test.exs`
  - `mix format --check-formatted`
- Notes:
  - Fixed heartbeat bug where `load_running_claims/1` previously passed the whole state into claim-touching, which could overwrite the state structure.
  - Final verifier fixed the restart-safety gap by renewing persisted running claims on reload/touch and adding a regression test for expired persisted claims occupying the active slot after restart.

## Verification

- 2026-06-27T00:00:00Z verifier note: starting fresh-context review of bounded dispatch changes; next steps are tracker state/workpad inspection, diff review, and targeted validation.
- 2026-06-27T16:25:00Z verifier note: resumed after implementer/final-verifier follow-up to re-check restart claim renewal, bounded slot accounting, and queue visibility before issuing the verifier verdict.
- Verifier findings:
  - `FAIL`: restart protection for long-running issues is incomplete. Dispatch claims are persisted only with their original expiry and `touch_running_claims/1` merely filters expired entries instead of extending them, so a claim older than the 10-minute TTL disappears on restart and frees a slot even if the underlying run is still active. Evidence: [orchestrator.ex](/var/lib/symphony/workspaces/SYM-22/elixir/lib/symphony_elixir/orchestrator.ex:1674), [orchestrator.ex](/var/lib/symphony/workspaces/SYM-22/elixir/lib/symphony_elixir/orchestrator.ex:1718), [orchestrator.ex](/var/lib/symphony/workspaces/SYM-22/elixir/lib/symphony_elixir/orchestrator.ex:1739), [orchestrator.ex](/var/lib/symphony/workspaces/SYM-22/elixir/lib/symphony_elixir/orchestrator.ex:920).
  - Coverage gap: the added tests validate queue capping and snapshot visibility, but there is no test exercising persisted-claim reload/refresh across a restart or expiry boundary. Evidence: [workspace_and_config_test.exs](/var/lib/symphony/workspaces/SYM-22/elixir/test/symphony_elixir/workspace_and_config_test.exs:511), [orchestrator_status_test.exs](/var/lib/symphony/workspaces/SYM-22/elixir/test/symphony_elixir/orchestrator_status_test.exs:24).
  - Validation run:
    - `mix test test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/orchestrator_status_test.exs` -> pass (`99 tests, 0 failures`)
    - `mix format --check-formatted` -> pass
    - `mix squad.check --file ../docs/codex-squad-evidence.md --workflow WORKFLOW.md` -> fail (verification PASS requirements not satisfied)
- Verifier (`gpt-5.4`) model: `gpt-5.4` — `FAIL`
- 2026-06-27T16:20:00Z final_verifier (gpt-5.5): confirmed the verifier restart finding still applied, patched claim renewal, and added `persisted restart claims are renewed and keep their active slot`.
- Final verifier validation:
  - `mix test test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/orchestrator_status_test.exs` -> pass (`100 tests, 0 failures`)
  - `mix format --check-formatted` -> pass
- Final verifier (`gpt-5.5`) model: `gpt-5.5` — `PENDING`
- 2026-06-27T16:35:00Z verifier (gpt-5.4): re-reviewed the bounded-dispatch diff after claim-renewal follow-up. `touch_running_claims/1` now renews persisted claims on load, `available_slots/1` counts the union of live `running` entries and persisted `running_claims`, the seven-candidate queue test still caps dispatch to three, and the restart regression now proves an expired persisted claim keeps its slot after reload.
- Verifier rerun validation:
  - `mix test test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/orchestrator_status_test.exs` -> pass (`101 tests, 0 failures`)
  - `mix format --check-formatted` -> pass
- [x] verifier (gpt-5.4): PASS
- 2026-06-27T16:15:37Z final_verifier note: starting final scope/evidence review after verifier PASS; will inspect the diff, rerun targeted validation including `mix squad.check`, then update the final PASS/FAIL row.
- 2026-06-27T16:17:02Z final_verifier (gpt-5.5): reviewed bounded-dispatch scope, config default, restart claim renewal, queue refill behavior, and status output. Found and fixed one final status accuracy gap: a queued candidate was not removed from `queued` when it claimed a slot, so runtime status could show the same issue as both dispatched and waiting. `claim_issue_for_dispatch/2` now removes the issue from the queue and the queue-refill regression asserts the dispatched issue no longer remains queued.
- Final verifier rerun validation:
  - `mix test test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/orchestrator_status_test.exs` -> pass (`101 tests, 0 failures`)
  - `mix format --check-formatted` -> pass
  - `git diff --check` -> pass
- [x] final_verifier (gpt-5.5): PASS
- 2026-06-27T16:27:42Z final_verifier (gpt-5.5): push-gate review found `make all` was executing tests under the caller's `MIX_ENV=dev`, which hid test-only helpers/dependencies and failed coverage. Fixed `elixir/Makefile` so `test` and `coverage` run with `MIX_ENV=test`, added the missing `State.t()` type for Dialyzer, and reran the full gate.
- Final verifier full-gate validation:
  - `MIX_ENV=dev make all` -> pass (`331 tests, 0 failures, 2 skipped`; coverage total `85.96%`; Dialyzer `passed successfully`)
