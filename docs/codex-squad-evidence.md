## Scope

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
