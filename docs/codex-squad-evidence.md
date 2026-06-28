## Scope

- Add a bounded MCP credential and scope preflight for configured external MCP tools, starting with Cloudflare MCP only.
- Discover Cloudflare MCP from the sanitized Codex config and/or an explicit Symphony preflight config section without storing OAuth tokens in Symphony state.
- Classify preflight outcomes into a non-secret status taxonomy that can represent `ok`, `missing_token`, `invalid_token`, `insufficient_scope`, `unreachable`, `unknown`, and `skipped_optional`.
- Enforce required-vs-optional policy before Codex turn dispatch: required Cloudflare MCP auth/scope failures become runtime blockers, while optional failures degrade with visible workpad/dashboard evidence.
- Keep all error and evidence text non-secret: name only the MCP server, status class, and required operator action.
- Add focused coverage for missing token, invalid token, insufficient scope, optional degrade, and required blocker behavior.
- Validate with MCP preflight unit tests, app-server runtime blocker tests, and a live e2e ticket requiring Cloudflare MCP that either runs or blocks with a precise non-secret reason.

Out of scope:

- Storing, copying, or logging MCP OAuth tokens in Symphony.
- Broad provider support beyond Cloudflare MCP in this first pass.
- Changing Codex model role prompts or unrelated dispatch/PR publication behavior.

## CTO Plan

- Role: cto
- Model: gpt-5.5
- Role turn: 1/4
- 2026-06-28T12:20:00Z CTO refresh: re-read the active Jira state/workpad and current workspace diff. The ticket remains active, the body still satisfies the content contract, and the bounded plan remains unchanged: implementer/verifier handoff should focus on Cloudflare MCP required-vs-optional preflight, non-secret evidence, live e2e proof, and required PASS rows. No new scope is added by this refresh.
- 2026-06-28 CTO continuation refresh: current workspace already contains MCP preflight implementation and verifier evidence; this CTO turn keeps the bounded scope unchanged and treats the existing verifier `FAIL` as implementation rework input for the next role, not as expanded scope.
- Ticket state observed: `진행 중` on 2026-06-28.
- Routing decision: continue active execution; create or refresh the single `## Codex Workpad` comment before implementation handoff.
- CTO refresh: repository already contains partial MCP preflight edits from the active run; this role preserves them and records the bounded policy/validation contract rather than widening implementation scope.

- Ticket contract review:
  - The supplied issue body contains `Background`, `Scope`, `Acceptance Criteria`, and `Validation` sections.
  - `Acceptance Criteria` and `Validation` contain checklist items and must be mirrored into the workpad as required checkboxes.
- Required-vs-optional tool policy:
  - A configured MCP server is `required` when the ticket, role, workflow, or explicit Symphony preflight config marks that server as needed for the run.
  - A configured MCP server is `optional` when present in sanitized Codex config but not required by the ticket/workflow/config for the current run.
  - Required Cloudflare MCP failures with status `missing_token`, `invalid_token`, or `insufficient_scope` must block before dispatching a Codex turn.
  - Optional Cloudflare MCP failures must not block unrelated work, but must emit dashboard/workpad evidence with server name, status class, and operator action.
  - Unknown/unreachable optional results should degrade visibly; unknown/unreachable required results may block only when the implementation cannot safely determine that dispatch can proceed.
- Status taxonomy:
  - `ok`: credential and required scope are usable.
  - `missing_token`: no token source is configured or visible to the runtime preflight.
  - `invalid_token`: provider signal indicates authentication failed.
  - `insufficient_scope`: provider signal indicates the token lacks required Cloudflare MCP scope/permission.
  - `unreachable`: provider endpoint or MCP handshake cannot be reached; message must not include headers, tokens, or raw request data.
  - `unknown`: provider returned an unclassified non-secret failure signal.
  - `skipped_optional`: optional preflight was intentionally not run or could not be run without blocking unrelated work.
- Implementation boundaries:
  - Prefer a small `MCPPreflight` module or similarly local boundary that returns structured results and a sanitized human message.
  - Integrate the required-blocker decision at the runtime dispatch/app-server boundary before a Codex turn is started.
  - Propagate optional degrade evidence through the existing dashboard/workpad evidence path already used for runtime blockers.
  - Keep tests deterministic with stubbed Cloudflare MCP/provider responses; do not require live Cloudflare credentials for unit tests.
- Reproduction target before code edits:
  - Capture the current lack of preflight by adding or running a deterministic test/proof showing a Cloudflare MCP auth failure is only surfaced after dispatch, or that no runtime blocker exists for a required MCP preflight failure.
- Validation criteria for implementer/verifiers:
  - Unit tests prove `missing_token`, `invalid_token`, and `insufficient_scope` produce sanitized result structs/messages.
  - Runtime blocker tests prove required Cloudflare MCP failures prevent dispatch before a Codex turn starts.
  - Optional degrade tests prove unrelated tickets continue while dashboard/workpad evidence records the non-secret preflight result.
  - Secret-safety review confirms no token value, authorization header, or provider raw credential material appears in logs, workpad notes, dashboard state, or evidence.
  - Required live e2e evidence records either a successful run with Cloudflare MCP available or a pre-dispatch block with only server, status class, and operator action.
  - `mix squad.check --file ../docs/codex-squad-evidence.md --workflow WORKFLOW.md` must not pass until implementer, verifier, and final_verifier rows are present with the required PASS evidence.

### CTO Code Landmarks And Risks

- Existing dispatch gate: `SymphonyElixir.Orchestrator.dispatch_issue/4` revalidates the issue, calls `preflight_issue_for_dispatch/1`, and only then calls `do_dispatch_issue/4`.
- Existing preflight hook: `preflight_issue_for_dispatch/1` currently chains ticket content preflight and persisted runtime-blocker comment inspection; it has no Cloudflare MCP credential/scope check.
- Existing blocker path: `block_issue_before_dispatch/4` can record a pre-dispatch runtime blocker in orchestrator state without starting an agent.
- Existing workpad propagation path: `post_runtime_blocker_comment/3` finds `## Codex Workpad` and appends a `### Runtime Blocker` section for runtime failures observed after a run starts; implementer should either reuse or narrowly extend this path for MCP preflight evidence.
- Existing app-server runtime blocker tests: `elixir/test/symphony_elixir/app_server_test.exs` already stubs a fake Codex binary to verify sanitized runtime blocker behavior.
- Existing ticket preflight tests: `elixir/test/symphony_elixir/ticket/config_preflight_test.exs` exposes `Orchestrator.preflight_issue_for_dispatch_for_test/1`, which is a good required-blocker regression seam.
- Existing sanitized Codex config boundary: `SymphonyElixir.Codex.ConfigFilter` writes workspace-local `.codex/config.toml` and symlinks runtime auth only when present; MCP discovery should consume key names/config shape without logging token values.
- Config gap: `SymphonyElixir.Config.Schema.Codex` currently has Codex runtime settings but no explicit MCP preflight config section, so implementer should choose between sanitized config discovery and a small explicit config addition.
- Status/dashboard gap: current status output tracks running, blocked, and queued issues, but there is no typed optional MCP degradation evidence field yet.
- Security risk: Cloudflare/provider error strings may include request details; sanitize down to server name, status class, and operator action before logging, storing, or attaching to comments.
- Reproduction/code-scan signal captured on 2026-06-28:
  - `preflight_issue_for_dispatch/1` currently calls only ticket content preflight and `runtime_blocker_preflight/1`.
  - `rg` found MCP handling for elicitation and startup/tool events, but no Cloudflare MCP credential/scope preflight before dispatch.
  - `ConfigFilter` tests already cover `[mcp_servers]` retention, making it the likely discovery boundary for configured MCP servers.
- Pull skill evidence:
  - `git pull --ff-only origin dev` result: clean/already up to date.
  - Explicit fetch of `origin/main` succeeded, but `git merge origin/main` failed with `fatal: refusing to merge unrelated histories`; no forced merge was performed in CTO planning.
  - Resulting `HEAD`: `22b24b5`.

## Implementation

- Role: implementer
- Model: `gpt-5.3-codex-spark`
- Role turn: 2/4
- Result:
  - Kept Cloudflare MCP preflight in `SymphonyElixir.Orchestrator` as the bounded implementation boundary and validated all pre-dispatch failure paths remain in-ticket-blocker flow.
  - Fixed verifier-identified crash path by guarding `Map.has_key?` access with the local `map_has_key?/2` helper when checking Cloudflare presence in configured Codex MCP entries, preventing non-map `codex_mcp_servers` values from raising `BadMapError`.
  - Normalized `missing_token` test behavior by generating a guaranteed-missing token key (`SYM35_TEST_MISSING_MCP_TOKEN_*`) in `elixir/test/symphony_elixir/ticket/config_preflight_test.exs`.
  - Added environment cleanup/restoration around that test and asserted emitted blocker messages contain no token key or value (`refute String.contains?(message, token_key)`).
  - Added regression coverage for unreadable Codex host config in `elixir/test/symphony_elixir/ticket/config_preflight_test.exs`:
    - `required Cloudflare MCP with unreadable codex host config returns sanitized blocker`
  - Executed required validation commands:
    - `cd elixir && mix test test/symphony_elixir/ticket/config_preflight_test.exs` (10 tests, 0 failures)
    - `cd elixir && mix test test/symphony_elixir/app_server_test.exs` (18 tests, 0 failures)
  - Outstanding verification remains with verifier/final verifier and live e2e blocker/degrade evidence.
  - `cd elixir && mix squad.check --file ../docs/codex-squad-evidence.md --workflow WORKFLOW.md` (failed: missing PASS rows for verifier/final_verifier)
- Follow-on verification (2026-06-28T20:20:00Z):
  - Re-ran MCP preflight unit tests with seed 0: `cd elixir && mix test test/symphony_elixir/ticket/config_preflight_test.exs --seed 0` (11 tests, 0 failures).
  - Re-ran app-server runtime blocker tests with seed 0: `cd elixir && mix test test/symphony_elixir/app_server_test.exs --seed 0` (18 tests, 0 failures).
  - Re-ran evidence gate: `cd elixir && mix squad.check --file ../docs/codex-squad-evidence.md --workflow WORKFLOW.md` (FAILED: verifier/final_verifier PASS rows are absent).
  - Current remaining implementation scope is complete; pending items are verifier/final_verifier handoff and live e2e evidence.

## Verification

- 2026-06-28T12:32:00Z verifier note: starting fresh verification on the current head after the optional-policy and unreadable-config fixes; reviewing the orchestrator diff, rerunning targeted tests, and checking that emitted blocker/degrade evidence stays non-secret before issuing the verifier verdict.
- 2026-06-28T12:36:00Z verifier (gpt-5.4): reviewed the current `orchestrator.ex` MCP preflight path and confirmed the prior verifier failures are addressed. `configured_mcp_preflight_results/0` now defaults Codex-config-only Cloudflare discovery to `required: false`, so unrelated tickets degrade with optional workpad evidence instead of blocking. Required workflow-declared failures still surface as pre-dispatch runtime blockers through `mcp_preflight_issue/1`, and both blocker/warning message builders emit only `server`, `status`, and `action`.
- Verifier validation rerun:
  - `cd elixir && mix test test/symphony_elixir/ticket/config_preflight_test.exs --seed 0` -> pass (`11 tests, 0 failures`)
  - `cd elixir && mix test test/symphony_elixir/app_server_test.exs --seed 0` -> pass (`18 tests, 0 failures`)
  - `cd elixir && mix format --check-formatted` -> pass
  - `git diff --check` -> pass
  - `cd elixir && mix squad.check --file ../docs/codex-squad-evidence.md --workflow WORKFLOW.md` -> fail only because `final_verifier (gpt-5.5)` PASS evidence is still missing
- Verifier findings:
  - No new code-level regression found in the bounded Cloudflare MCP preflight scope. Targeted tests now cover required `missing_token`, `invalid_token`, `insufficient_scope`, unreadable/missing Codex config, optional degrade, and the Codex-config-only optional path without leaking token keys or values.
- [x] verifier (gpt-5.4): PASS
- 2026-06-28T12:05:00Z verifier note: resumed fresh-context verification after the unreadable-config fix; reviewing the current diff, rerunning targeted preflight/app-server tests, and checking non-secret warning/blocker propagation before issuing the verifier verdict.
- Verifier findings:
  - `FAIL`: Cloudflare MCP servers discovered only from sanitized Codex config are treated as implicitly `required`, so missing credentials block unrelated tickets instead of degrading visibly. In `configured_mcp_preflight_results/0`, the `required` field defaults to `map_has_key?(codex_servers, @cloudflare_mcp_name)`, which becomes `true` whenever the sanitized Codex config contains a Cloudflare MCP stanza even if workflow `mcp_preflight` does not mark it required. Evidence: [orchestrator.ex](/var/lib/symphony/workspaces/SYM-35/elixir/lib/symphony_elixir/orchestrator.ex:1523). Reproduction: `MIX_ENV=test mix run <temp script>` with only `[mcp_servers.cloudflare]` in the Codex config and no workflow `mcp_preflight` section returns `{:error, {:runtime_blocker, "server=cloudflare status=missing_token action=configure Cloudflare MCP credentials"}}` instead of allowing dispatch with optional warning evidence.
- Verifier validation:
  - `cd elixir && mix test test/symphony_elixir/ticket/config_preflight_test.exs --seed 0` -> pass (`10 tests, 0 failures`)
  - `cd elixir && mix test test/symphony_elixir/app_server_test.exs --seed 0` -> pass (`18 tests, 0 failures`)
  - `cd elixir && MIX_ENV=test mix run <temp script>` -> fail against ticket policy (Codex-config-only Cloudflare MCP blocks dispatch as required)
- [ ] verifier (gpt-5.4): FAIL - Codex-config-only Cloudflare MCP defaults to required and blocks unrelated tickets instead of degrading as optional evidence.
- 2026-06-28T11:46:00Z verifier note: reviewed the Cloudflare MCP preflight diff and ran targeted verification against the new dispatch gate before issuing the role verdict.
- Verifier findings:
  - `FAIL`: required Cloudflare MCP preflight can crash before dispatch when the Codex host config path is unreadable or absent. `codex_mcp_servers/0` returns `[]` on read failure, but `configured_mcp_preflight_results/0` and `token_env_refs_for/2` treat that value as a map and raise `BadMapError` instead of returning a sanitized runtime blocker or a clean no-config result. Evidence: [orchestrator.ex](/var/lib/symphony/workspaces/SYM-35/elixir/lib/symphony_elixir/orchestrator.ex:1507), [orchestrator.ex](/var/lib/symphony/workspaces/SYM-35/elixir/lib/symphony_elixir/orchestrator.ex:1673), [orchestrator.ex](/var/lib/symphony/workspaces/SYM-35/elixir/lib/symphony_elixir/orchestrator.ex:1692).
- Verifier validation:
  - `cd elixir && mix test test/symphony_elixir/ticket/config_preflight_test.exs --seed 0` -> pass (`8 tests, 0 failures`)
  - `cd elixir && mix run -e '...required cloudflare preflight with missing codex_host_config_path...'` -> fail with `** (BadMapError) expected a map, got: []`
- [ ] verifier (gpt-5.4): FAIL - unreadable/missing Codex host config crashes MCP preflight instead of yielding a non-secret blocker/degrade result.
- Pending final_verifier role (`gpt-5.5`).
- 2026-06-28T11:30:00Z final_verifier note: starting final verification from the current workspace diff, with focus on the verifier-reported missing/unreadable Codex host config crash, non-secret evidence, and required `squad.check` gate.
- 2026-06-28T17:40:10Z: Implementer sync note: `git pull --ff-only origin dev` run again in this continuation, result `already up to date` at HEAD `22b24b5`.

Final verifier gpt-5.5 note (2026-06-28T12:01:51Z): starting final evidence/diff validation before tracker updates.
- 2026-06-28T12:15:00Z final_verifier (gpt-5.5): fixed the verifier-reported Codex-config-only Cloudflare MCP policy gap by defaulting Codex-discovered MCP servers to optional unless the workflow `mcp_preflight` config explicitly marks them required.
- Final verifier code review:
  - Required Cloudflare MCP failures still return sanitized runtime blockers before dispatch.
  - Optional workflow-declared MCP failures still create a workpad warning and allow dispatch.
  - Codex-config-only Cloudflare MCP with a missing env token now creates optional workpad evidence and allows dispatch.
  - Sanitized blocker/degrade messages include only `server`, `status`, and `action`; the new regression asserts the token env key is not emitted.
- Final verifier validation:
  - `cd elixir && mix test test/symphony_elixir/ticket/config_preflight_test.exs --seed 0` -> pass (`11 tests, 0 failures`)
  - `cd elixir && mix test test/symphony_elixir/app_server_test.exs --seed 0` -> pass (`18 tests, 0 failures`)
  - `cd elixir && mix format --check-formatted` -> pass
  - `git diff --check` -> pass
  - `cd elixir && mix squad.check --file ../docs/codex-squad-evidence.md --workflow WORKFLOW.md` -> fail because the required successful verifier rows are absent before this verdict.
- [ ] final_verifier (gpt-5.5): FAIL - implementation validation succeeds after the final policy fix, but terminal handoff is blocked until a fresh successful verifier verdict exists and the live e2e validation requirement is satisfied.
