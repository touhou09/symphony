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

---

## Prior Merged Evidence (SYM-16 and SYM-15)

Role: cto
Model: gpt-5.5
Result: COMPLETE

The trusted Codex configuration boundary for SYM-16 is the container runtime,
not the host user's full `~/.codex/config.toml`. The container may consume a
minimal, generated or filtered Codex config that preserves required runtime
keys by name and derives secret-bearing values only from runtime mounts or
environment, while excluding host-local and cache-like state such as
`hooks.state`.

In scope for implementation:

- Trace the current Compose/container bootstrap path that supplies
  `/root/.codex/config.toml` to the Codex app-server container.
- Introduce a container-safe config generation or filtering path used by the
  orchestrator container before Codex app-server parses configuration.
- Preserve required settings for model selection, authentication wiring, MCP
  servers, and project trust without committing token values or printing them
  in logs/evidence.
- Add regression coverage for volatile host sections, including `hooks.state`,
  and a reproducible smoke that proves Codex app-server parses or starts with
  the safe config.
- Document required container Codex keys by key name only.

Out of scope:

- Editing the host user's Codex config as the permanent fix.
- Committing, printing, or storing token values.
- Changing ticket dispatch semantics except for config bootstrap changes
  required to supply the safe container config.

## CTO Plan

- Role: cto
- Model: gpt-5.5

- Reproduce the current failure mode with a host-style config containing
  `hooks.state` or equivalent volatile state before code changes.
- Inspect Compose, image, and runtime bootstrap files to locate where
  `/root/.codex/config.toml` is mounted, copied, or generated.
- Implement the narrowest boundary: generate or filter a container-specific
  config file and point Codex app-server at that file/path, keeping secrets in
  existing runtime mechanisms.
- Add focused tests that prove volatile sections are removed or ignored while
  required key families remain represented.
- Add documentation listing required keys only, with no secret examples.
- Validate with targeted config/bootstrap tests, `mix format --check-formatted`,
  `mix specs.check`, and a sanitized container smoke command.
- Run verifier and final verifier roles after implementation; the Verification
  section must contain PASS rows for both before the issue can be marked successful.

## CTO Findings

- Current unsafe source: `docker-compose.yml` bind-mounts
  `${HOME}/.codex/config.toml` directly to `/root/.codex/config.toml:ro`.
- Current secret source: `docker-compose.yml` bind-mounts
  `${HOME}/.codex/auth.json` to `/root/.codex/auth.json:ro`. Keep this as a
  runtime-only secret mount; do not copy or document token values.
- Current bootstrap: `elixir/deploy/entrypoint.sh` only creates
  `/root/.codex`; it does not sanitize or generate config.
- Current app-server launch path: `SymphonyElixir.Codex.AppServer` runs
  `bash -lc <codex.command>` from the issue workspace. Squad roles already
  inject model overrides into `codex.command`, so the fix can stay within the
  existing command/bootstrap surface.
- Reproduction signal: a synthetic workspace-local `$HOME/.codex/config.toml`
  with `hooks.state = { last_seen = "volatile" }` caused Codex app-server to
  log `invalid type: string "volatile", expected struct HookStateToml`.

## Runtime Boundary

The implementer should prefer a container-owned safe config path over mounting
the host config wholesale:

- Remove or replace the direct host config bind mount in Compose.
- Add an explicit runtime input path for the host config when filtering is
  needed, for example a read-only mount under `/run/symphony/codex-host/`.
- Generate `/root/.codex/config.toml` inside the container before Symphony
  starts, or point `codex.command` at a generated safe file if the installed
  Codex CLI supports a config-file flag.
- The generated config must preserve only supported, durable key families
  needed by the container runtime. At minimum, preserve/document these key
  names when present: `model`, `model_reasoning_effort`,
  `shell_environment_policy`, `mcp_servers`, and `projects`.
- The generated config must exclude volatile/cache-like state, including
  `hooks.state`, and should treat any future host-only state as denylisted
  rather than passing unknown nested state blindly.
- Authentication must continue to come from `/root/.codex/auth.json` or
  environment-backed runtime mechanisms. No token values should appear in
  tracked files, test output, smoke evidence, or workpad text.

## Validation Design

- Add a focused unit test around the generator/filter using an input TOML with
  `hooks.state`; assert the output omits volatile state and retains required
  safe key names.
- Add a Compose/render or entrypoint-level test that proves host config is not
  mounted directly to `/root/.codex/config.toml`.
- Add documentation of required container Codex settings by key name only.
- Container smoke should run against a synthetic config containing
  `hooks.state` and report only non-secret evidence, such as the generated
  config path, absence of `hooks.state`, and successful parse/startup status.

## Implementation

- Role: implementer
- Model: gpt-5.3-codex-spark
- Result: COMPLETE

### Implementation notes

- Added `SymphonyElixir.Codex.ConfigFilter` to generate a filtered per-workspace
  config copy and prepend `HOME=<workspace>/.codex` for local app-server launches.
- Updated `docker-compose.yml` to mount host `~/.codex/config.toml` at
  `/run/symphony/codex-host/config.toml` instead of `/root/.codex/config.toml`.
- Added `elixir/test/symphony_elixir/config_filter_test.exs` regression tests for:
  - removing inline `hooks.state`
  - removing `[hooks.state]` table blocks
  - returning the original command when host config is unavailable.

## Verification

- [x] implementer (gpt-5.3-codex-spark): PASS - implementation completed.
- [x] verifier (gpt-5.4): PASS - previous FAIL finding was reproduced,
  fixed, and covered by regression validation.
- [x] final_verifier (gpt-5.5): PASS - evidence, security boundary,
  regression fix, and required validation reviewed.

### Final Verifier Start

- Role: final_verifier
- Model: gpt-5.5
- Started: 2026-06-27T15:55:05Z
- Initial finding: previous verifier recorded a real regression in inline
  `hooks.state` filtering; final verification will first inspect and repair the
  narrow sanitizer behavior before rerunning validation.

## Implementation Outcome (updated)

- `ConfigFilter` now writes sanitized config to `<workspace>/.codex/config.toml`.
- `codex.command` injection now prepends `HOME=<workspace>/.codex`.
- This avoids the `--config` positional flag mismatch (which expects override values).
- Added fallback guard to ignore non-regular host config mount paths and preserve
  existing launch behavior when sandboxing cannot source a file.

## Validation outputs

- `cd elixir && mix test test/symphony_elixir/config_filter_test.exs`
  - `3 tests, 0 failures`
- `cd elixir && mix format --check-formatted`
  - passes
- `cd elixir && mix specs.check`
  - `specs.check: all public functions have @spec or exemption`
- Container smoke (sanitized path):
  - invalid config with hooks: `codex_exit=0` plus
    `invalid type: string "volatile", expected struct HookStateToml` (expected for unfiltered input)
  - sanitized config with same source keys excluding `hooks.state`: `contains_hooks_error=no`
    and app-server launch executed with `codex_exit=0`.
- Final verifier regression and smoke after fix:
  - `cd elixir && mix test test/symphony_elixir/config_filter_test.exs`
    -> `3 tests, 0 failures`
  - `cd elixir && mix format --check-formatted` -> passes
  - `cd elixir && mix specs.check`
    -> `specs.check: all public functions have @spec or exemption`
  - synthetic sanitized app-server smoke:
    `safe_config_exists=true`, `contains_hooks_state=false`,
    `contains_shell_environment_policy=true`, `codex_status=0`,
    `contains_hooks_parse_error=no`
  - `cd elixir && mix squad.check --file ../docs/codex-squad-evidence.md --workflow WORKFLOW.md`
    -> `squad.check: evidence contract OK`
  - `MIX_ENV=dev make -C elixir all` was attempted for the push-skill gate.
    It passed setup, build, format, lint, and example squad-check after the
    final lint cleanup, then failed in the broader existing coverage suite with
    `OrchestratorStatusTest` setup failures because `SymphonyElixir.Supervisor`
    was not running, plus coverage below the repository threshold. This is
    outside the SYM-16 config-filter path; targeted ticket validation passed.

## Verifier Findings

- Role: verifier
- Model: gpt-5.4
- Result: FAIL

Focused verification found a regression in inline `hooks.state` filtering.
`sanitize_config_contents/1` treats an inline `hooks.state = { ... }` line as
the start of a skipped section, so it also drops subsequent top-level durable
keys until the next TOML section header. That breaks the required boundary:
volatile state is removed, but valid settings after it are lost too.

Concrete reproduction:

- Command:
  `elixir -e 'Code.require_file("elixir/lib/symphony_elixir/codex/config_filter.ex"); input = "model = \"gpt-5.3\"\nhooks.state = { last_seen = \"volatile\" }\nshell_environment_policy = \"inherit=all\"\n[projects]\nfoo = \"bar\"\n"; IO.puts(SymphonyElixir.Codex.ConfigFilter.sanitize_config_contents(input))'`
- Output:
  ```text
  model = "gpt-5.3"
  [projects]
  foo = "bar"
  ```
- Missing durable key after filtering:
  `shell_environment_policy = "inherit=all"`

Verifier validation summary:

- `cd elixir && mix test test/symphony_elixir/config_filter_test.exs` -> passes,
  but the regression test is incomplete because it does not assert durable key
  retention after inline `hooks.state`.
- `cd elixir && mix format --check-formatted` -> passes.
- `cd elixir && mix specs.check` -> passes.

## Final Verifier Findings

- Role: final_verifier
- Model: gpt-5.5
- Result: PASS

The verifier's failed reproduction was valid. The final patch changes inline
`hooks.state = ...` handling to drop only that assignment while keeping normal
top-level keys that follow it. Denied `[hooks.state]` and `[[hooks.state]]`
tables still skip until the next TOML section.

Security boundary review:

- Host auth remains a runtime-only `/root/.codex/auth.json` mount.
- Host config is no longer mounted directly to `/root/.codex/config.toml`;
  Compose exposes it at `/run/symphony/codex-host/config.toml`.
- The app-server launch writes a workspace-local sanitized
  `<workspace>/.codex/config.toml` and sets `HOME=<workspace>/.codex` only for
  local container execution.
- Evidence and tests list key names only and do not include token values.

## Handoff Evidence

- PR URL: https://github.com/touhou09/symphony/pull/11
- Config path summary: host config is mounted read-only at
  `/run/symphony/codex-host/config.toml`; sanitized runtime config is written
  to `<workspace>/.codex/config.toml`; auth remains mounted separately at
  `/root/.codex/auth.json`.
- Required container config key names documented in evidence only:
  `model`, `model_reasoning_effort`, `shell_environment_policy`,
  `mcp_servers`, and `projects`.
- PR checks on commit `a222d2c`: `make-all` success,
  `validate-pr-description` success.

---

## Prior Merged Evidence (SYM-15)

- Ticket: SYM-15
- Role: cto
- Model: gpt-5.5
- Decision: remove `mise` from completion hook commands instead of adding `mise` to the Compose orchestrator image.
- Runtime contract: Compose orchestrator hooks run inside the orchestrator container with `/usr/bin/sh`, `git`, `docker`, Elixir, Mix, and the checked-out workspace available. Hooks must not require host-only version managers unless the image explicitly installs them.
- In scope:
  - Update `elixir/WORKFLOW.md` `hooks.after_complete` and `hooks.before_remove` to run container-stable commands.
  - Keep `hooks.after_create` tolerant of absent `mise`; it already checks `command -v mise` before using it.
  - Add or update regression coverage showing default completion/remove hooks do not reference unconditional `mise exec`.
  - Add or update hook execution/failure reporting coverage if existing tests do not already prove real hook failures are logged and ignored/surfaced appropriately.
  - Run a local or Compose smoke that exercises `after_complete` and `before_remove` without `mise` and captures sanitized output showing no `mise: not found` or status `127`.
- Out of scope:
  - Jira credentials, GitHub tokens, deploy secrets, and unrelated squad workflow changes.
  - Broad refactors of hook execution, PR publishing, or workspace cleanup behavior beyond this dependency fix.

## CTO Plan

- cto / gpt-5.5 inspected `elixir/WORKFLOW.md`, `docker-compose.yml`, and `elixir/deploy/orchestrator.Dockerfile`.
- Reproduction target:
  - Current `after_complete` command is `cd elixir && mise exec -- mix workspace.publish_pr ...`.
  - Current `before_remove` command is `cd elixir && mise exec -- mix workspace.before_remove`.
  - The orchestrator Dockerfile does not install `mise`, so those hooks can fail with shell status `127` in Compose.
- Implementation direction:
  - Prefer `cd elixir && mix workspace.publish_pr --repo ... --base ...` for `after_complete`.
  - Prefer `cd elixir && mix workspace.before_remove` for `before_remove`.
  - Do not remove the optional `after_create` `mise` bootstrap guard unless tests prove it creates an unconditional runtime dependency; its current `command -v mise` guard is acceptable.
- Regression coverage:
  - Update workflow/config tests that currently assert `mise exec` in completion hooks.
  - Add assertions that `after_complete` and `before_remove` contain the expected `mix workspace.*` commands and do not contain `mise`.
  - Preserve or add tests proving `before_remove` and `after_complete` hook failures are logged/ignored as designed while `after_create` still surfaces blocking failures.
- Required validation before handoff:
  - Targeted hook/config ExUnit tests.
  - `mix format --check-formatted`.
  - `mix specs.check`.
  - `mix squad.check --file docs/codex-squad-evidence.md --workflow WORKFLOW.md` after implementer/verifier/final verifier evidence exists.
  - Sanitized local or Compose smoke proving both completion hooks execute in an environment where `mise` is absent without `mise: not found` or status `127`.

## Implementation

- Role: implementer
- Model: gpt-5.3-codex-spark
- Scope executed: remove `mise` dependency from `after_complete` and `before_remove` default hook commands in `elixir/WORKFLOW.md`.
- Files changed:
  - `elixir/WORKFLOW.md`
  - `elixir/test/symphony_elixir/core_test.exs`
  - `elixir/test/symphony_elixir/workspace_and_config_test.exs`
- Result: completion hooks now call `mix workspace.publish_pr` and `mix workspace.before_remove` directly; tests added for failure logging semantics.
- Status: changes are in working tree and pending validation.

### Validation (gpt-5.3-codex-spark)

- `mix format --check-formatted`: pass.
- `mix specs.check`: pass.
- `ERL_FLAGS="+S 1" mix test test/symphony_elixir/core_test.exs test/symphony_elixir/workspace_and_config_test.exs`: pass (`103 tests, 0 failures`).
- Local smoke probe executed from repo path with no `mise` in PATH and both tasks exposed via `mix help`:
  - `HOOK_SMOKE_BEFORE_PATH=MISSINPATH`.
  - `mix workspace.publish_pr` and `mix workspace.before_remove` help text displayed.
- `mix squad.check --file ../docs/codex-squad-evidence.md --workflow WORKFLOW.md`: fail pending verifier/final_verifier PASS rows.

## Verification

- verifier / gpt-5.4 started fresh verification on 2026-06-27 UTC; validating diff, hook failure reporting, and no-`mise` runtime behavior before recording PASS/FAIL.
- Diff review:
  - `elixir/deploy/orchestrator.Dockerfile` still does not install `mise`, so removing `mise exec` from completion hooks is consistent with the actual container runtime.
  - `elixir/WORKFLOW.md` now leaves `after_create` guarded by `command -v mise` and removes unconditional `mise` usage from `after_complete` and `before_remove`.
  - `elixir/test/symphony_elixir/core_test.exs` now asserts the default completion/remove hooks call `mix workspace.*` directly and refutes `mise exec`.
  - `elixir/test/symphony_elixir/workspace_and_config_test.exs` adds regression coverage that `after_complete` and `before_remove` failures still log hook name, status, and output.
- Fresh verifier validation:
  - `ERL_FLAGS="+S 1" mix test test/symphony_elixir/core_test.exs test/symphony_elixir/workspace_and_config_test.exs --max-failures 1`: pass (`103 tests, 0 failures`) on rerun from fresh context.
  - `PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin sh -lc 'cd /var/lib/symphony/workspaces/SYM-15/elixir && echo "HOOK_SMOKE_MISE=$(command -v mise || echo MISSINPATH)" && grep -n "after_complete:\\|before_remove:" WORKFLOW.md && mix help workspace.publish_pr && mix help workspace.before_remove'`: pass with `HOOK_SMOKE_MISE=MISSINPATH` and no `mise: not found`.
  - `mix squad.check --file ../docs/codex-squad-evidence.md --workflow WORKFLOW.md`: expected fail before final handoff because `final_verifier` PASS row is still absent.
- [x] verifier (gpt-5.4): PASS - diff matches container runtime, targeted hook regression tests passed, and no-`mise` smoke stayed clear of status `127`.
- final_verifier / gpt-5.5 started final evidence review on 2026-06-27 UTC; checking the diff, rerunning required validation, and confirming squad evidence before PASS/FAIL.
- Final verifier validation:
  - Diff review confirmed only `WORKFLOW.md` default completion/remove hooks and hook regression tests changed; no secrets or credentials were touched.
  - `ERL_FLAGS="+S 1" mix test test/symphony_elixir/core_test.exs test/symphony_elixir/workspace_and_config_test.exs --max-cases 1 --max-failures 1`: pass (`103 tests, 0 failures`). A prior non-serialized rerun failed once with `WorkflowStore` shutdown while other agents were visible in the test status UI; serialized rerun passed and did not reproduce.
  - `mix format --check-formatted`: pass.
  - `mix specs.check`: pass (`specs.check: all public functions have @spec or exemption`).
  - No-`mise` smoke: `PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin sh -lc ...` returned `HOOK_SMOKE_MISE=MISSINPATH`, showed `after_complete` / `before_remove` use direct `mix workspace.*` commands, and emitted no `mise: not found`.
- Post-merge final verifier validation:
  - Merged `origin/dev` into `sym-15-compose-hook-mise-runtime`; resolved the add/add evidence conflict by keeping the SYM-15 evidence.
  - `ERL_FLAGS="+S 1" mix test test/symphony_elixir/core_test.exs test/symphony_elixir/workspace_and_config_test.exs --max-cases 1 --max-failures 1`: pass (`103 tests, 0 failures`).
  - `mix format --check-formatted`: pass.
  - `mix specs.check`: pass (`specs.check: all public functions have @spec or exemption`).
  - `mix squad.check --file ../docs/codex-squad-evidence.md --workflow WORKFLOW.md`: pass (`squad.check: evidence contract OK`).
  - No-`mise` smoke with restricted PATH returned `HOOK_SMOKE_MISE=MISSINPATH`, showed direct `mix workspace.*` hook commands, and emitted no `mise: not found`.
  - `make -C elixir all`: fail because the shell used a non-dev Mix environment where `mix credo` is unavailable.
  - `MIX_ENV=dev make -C elixir all`: setup, build, format, lint, and squad-check passed; coverage failed on pre-existing/unrelated full-suite issues (`lazy_html` unavailable in dev coverage LiveView tests and a retry-backoff timing assertion).
  - PR published: https://github.com/touhou09/symphony/pull/10 against `dev` with the `symphony` label.
  - PR feedback sweep: zero top-level comments, zero inline comments, zero reviews.
  - GitHub checks on the PR branch were polled after publish: `validate-pr-description` success, `make-all` success.
- [x] final_verifier (gpt-5.5): PASS - required SYM-15 validation passed, evidence contains verifier and final_verifier PASS rows, and residual risk is limited to existing environment-sensitive/full-suite issues outside the hook dependency change.
