## 2026-06-27: SYM-6 real Codex dispatch smoke [blocked]
- **What**: Created first real Jira dispatch ticket `SYM-6`, rebuilt Compose orchestrator, fixed UTF-8 workflow parsing, and added Jira-mode tracker dynamic tools for Codex app-server.
- **Why**: The first real run exposed two runtime-only gaps: regex newline parsing corrupted Korean prompt bytes, and Jira mode still exposed only the legacy Linear dynamic tool.
- **Impact**: Symphony can now pick up SYM Jira tickets, start Codex, create a Jira workpad, and move the issue to active work, but true repo implementation still stalls before producing a workspace diff.
- **Test**: Targeted ExUnit 24/24, `mix run` confirmed Jira-mode tools only, Compose rebuild succeeded, `SYM-6` moved to `Work in progress`, and Jira comment count became 1.
- **Trap**: Letting the run continue burned tokens without code changes because the workflow requires editable single-workpad behavior while the current tracker tool surface can only create comments, not list/update them.
- **Next**: Add Jira comment list/update dynamic tools or relax the workflow workpad requirement before re-enabling unattended real-Codex runs.
---

## 2026-06-27: SYM-6 workpad tools and Docker runtime unblocks [blocked]
- **What**: Added tracker comment list/update tools for Jira app-server mode, switched Docker Codex turns away from Bubblewrap sandboxing, and baked runtime Hex/Rebar/build tooling into the orchestrator image.
- **Why**: Real SYM-6 runs needed to reuse one Jira workpad comment, execute shell commands inside Docker, and run Mix checks from the cloned workspace instead of failing before implementation.
- **Impact**: SYM-6 can now reuse comment `11381`, update its workpad, run repository commands in `/var/lib/symphony/workspaces/SYM-6`, and continue past the prior Bubblewrap/Hex blockers.
- **Test**: `mix format`, focused ExUnit 38/38, `mix run` confirmed Jira tool list `get/list/add/update/transition`, `docker compose build orchestrator`, live Jira workpad update, and repo commands recorded as successful in the workpad.
- **Trap**: After runtime blockers were cleared, the broad phase-2 ticket still consumed high tokens with no workspace diff; the unattended runner needs a no-diff/token guard and smaller implementation tickets before further real-Codex dispatch.
- **Next**: Add an orchestrator token/no-diff stop condition, split SYM-6 into bounded implementation tickets, or pre-seed a narrower branch/spec before restarting unattended execution.
---
## 2026-06-27: Multi-model squad runtime and no-diff guard [done]
- **What**: Added `agent.squad_enabled`, per-role Codex app-server command overrides, sequential CTO/implementer/verifier/final_verifier sessions, `squad.check` evidence validation after role turns, and a no-diff token guard.
- **Why**: SYM-6 proved prompt-only squad routing was too weak: the model updated the workpad but did not produce repo changes, so runtime-level role separation and runaway protection were needed.
- **Impact**: Compose deployments can now run distinct configured Codex model contexts per role and stop cleanly when a broad ticket consumes tokens without workspace changes.
- **Test**: `mix format`, focused ExUnit 43/43, `mix squad.check --file docs/codex-squad-evidence.example.md --workflow WORKFLOW.md`, `mix run --no-start` config parse, `docker compose build orchestrator`, live SYM-6 smoke showed Jira workpad update with empty workspace diff.
- **Trap**: SYM-6 remains too broad for unattended completion in one ticket; the live run reached 162,010 tokens with no git diff and was stopped after confirming the guard/build path.
- **Next**: Persist runtime blocker state into the Jira workpad/status so Compose restarts do not redispatch the same no-diff blocker automatically.
---

## 2026-06-27: Persisted no-diff runtime blocker [done]
- **What**: Persisted no-diff token blocks into the tracker workpad and taught dispatch preflight to honor the marker before spawning Codex.
- **Why**: GenServer blocked state disappears on Compose restarts, so SYM-6 could be redispatched after a no-diff token stop unless the blocker lived in Jira.
- **Impact**: Active Jira tickets with the runtime blocker marker are blocked before Codex starts, reducing repeat token burn on broad/no-diff work.
- **Test**: Focused ExUnit 12/12, `mix format --check-formatted`, `mix squad.check`, `docker compose build orchestrator`, Jira workpad `11381` marker update, and live preflight marker detection OK.
- **Next**: Split SYM-6 into smaller implementation tickets or remove the marker only after the ticket is narrowed enough for a real diff-producing run.
---

## 2026-06-27: E2E dispatch unblocked and Compose started [in-progress]
- **What**: Removed the persisted SYM-6 no-diff runtime blocker marker and started the Docker Compose orchestrator for a live E2E run.
- **Why**: The user requested marker removal and a real E2E dispatch opportunity after split-ticket validation.
- **Impact**: SYM-6 and split tickets SYM-7 through SYM-10 are running concurrently under the configured max concurrency.
- **Test**: SYM-6 preflight returned OK after marker removal; Compose status shows orchestrator up; dashboard/log tail shows 5 active agents with token accounting active.
- **Next**: Monitor workspaces/Jira workpads for diff, evidence, verifier PASS, no-diff blockers, or terminal transitions.
---

## 2026-06-27: SYM-11 no-diff guard hardening [done]
- **What**: Hardened SYM-11 remediation so tracker workpad writes require a real workspace diff, role prompts require first-edit evidence, and no-diff blocking runs on token events, poll cycles, and normal worker exit.
- **Why**: Live one-ticket smoke showed Codex could briefly emit turn diff previews or finish normally while leaving the git workspace clean, bypassing the original event-only guard.
- **Impact**: Bounded SYM tickets now either leave a repository evidence diff, or persist a Jira runtime blocker before redispatch/retry loops can continue.
- **Test**: `mix format --check-formatted`, targeted ExUnit 24/24, `mix ticket.check` OK, `mix squad.check` OK, Docker Compose rebuild OK, and SYM-11 one-ticket smoke produced persistent `docs/codex-squad-evidence.md` diff before the temp stack was stopped.
- **Trap**: A prior smoke with old guard exited clean with no persistent diff; the fix added the normal `:DOWN` guard and regression test for that exact path.
---

## 2026-06-27: SYM-12 CI/CD E2E smoke [blocked]
- **What**: Created SYM-12 for CI checks plus merge-triggered CD and let the live Symphony orchestrator dispatch it from Jira.
- **Why**: Verify the new `dev`-based Symphony flow with a realistic ticket that should produce a branch, PR, and review handoff.
- **Impact**: Intake, Jira state transition, workspace clone from `touhou09/symphony@dev`, and CTO evidence generation worked; implementation-to-PR handoff did not complete.
- **Test**: Ticket preflight passed in both skill and repo checkers; SYM-12 reached `진행 중`, created `/var/lib/symphony/workspaces/SYM-12`, but only produced `docs/codex-squad-evidence.md` and no PR before the run was stopped at about 597,500 tokens.
- **Trap**: `codex.max_no_diff_tokens` was disabled for the `dev` deployment, so evidence-only progress bypassed the previous no-diff stop; SYM-12 was commented with the smoke result and moved to `취소` to prevent redispatch.
---

## 2026-06-27: GitHub token publish path [done]
- **What**: Wired `GH_TOKEN`/`GITHUB_TOKEN` into Compose and taught the publish hook to use env-backed git askpass plus GitHub API PR creation when `gh` is unavailable.
- **Why**: Live SYM-6/SYM-13 handoff showed HTTPS push and GitHub connector auth failures, while the orchestrator image does not include `gh`.
- **Impact**: A rotated token in the ignored `.env` can authenticate `git push` and PR creation without storing token values in git config or command args.
- **Test**: `mix format --check-formatted`, targeted ExUnit 67/67, `git diff --check`, Docker image build OK, probe Compose run receives `GH_TOKEN`, token shape check passed, GitHub API probe returned 200, and `git ls-remote` succeeded.
- **Next**: Continue monitoring live SYM-6/SYM-13/SYM-11 publication for PR creation.
---

## 2026-06-27: Dev-lane CI activation [done]
- **What**: Activated `make-all` for `dev`, then cleared the strict lint, coverage, flaky timing, and dialyzer blockers exposed by PR #8.
- **Why**: The active Symphony development lane needed a real GitHub Actions signal before merging accumulated work back to `main`.
- **Impact**: `dev` pushes can now surface build/lint/test/coverage/dialyzer regressions; the coverage gate starts at the observed 85% baseline.
- **Test**: Local `mix format --check-formatted`, `mix specs.check`, `mix test --cover` 323/323, `mix dialyzer --format short`, `git diff --check`, and GitHub Actions run 28291515215 passed.
- **Trap**: Enabling CI exposed sequential stale debt: Credo strict failures, an impossible 100% coverage threshold, one scheduler-sensitive assertion, and two unreachable dialyzer clauses.
---

## 2026-06-28: Self-hosted Compose deploy runner [done]
- **What**: Registered the Mac as `symphony-compose-deploy` and changed main deploy to run on that self-hosted runner instead of GitHub-hosted SSH.
- **Why**: `mac.dororong.dev` is reachable locally through Cloudflare Access but not by plain SSH from GitHub-hosted runners.
- **Impact**: Main deploy can update the local checkout and rebuild only the `orchestrator` service without exposing a public SSH endpoint.
- **Test**: GitHub runner API reported `symphony-compose-deploy` online; PR #23 main push ran `make-all` in 47s and deploy in 37s; Compose recreated `symphony-orchestrator-1`.
- **Trap**: The deploy target was still on local `dev` with tracked worklog edits; workflow now resets tracked changes before switching to `main`.
---

## 2026-06-28: Total token budget blocker [done]
- **What**: Added a configurable `codex.max_total_tokens` guard and set the Compose workflow default to 1,500,000 tokens per running issue.
- **Why**: Live SYM-23 e2e proved auth was fixed but a diff-producing role could still climb past 6M tokens, bypassing the no-diff guard.
- **Impact**: Future runaway issues stop as runtime blockers even when workspace diffs exist, preserving the Jira workpad evidence and active slot state.
- **Test**: PR #24 and #25 checks passed; main deploy succeeded; live SYM-21 blocked at 1,510,078/1,500,000 tokens and SYM-23 blocked at 1,539,416/1,500,000 tokens with no retry observed.
- **Trap**: Local strict Credo still crashes on existing test sigils under Elixir 1.20.1; CI uses Elixir 1.19.5 for the full check.
---

## 2026-06-28: Workspace runtime file exclude [done]
- **What**: Added workspace-local git excludes for Codex runtime home and Mix cache directories created during isolated HOME execution.
- **Why**: Live SYM-23 left `.codex/auth.json`, sanitized config, and cache directories visible to `git status`, which could pollute `workspace.publish_pr` because it stages with `git add -A`.
- **Impact**: Future Symphony workspaces can still use mounted Codex auth while publish hooks ignore runtime-only files and avoid committing auth symlinks or cache noise.
- **Test**: `mix format --check-formatted`, config filter tests 5/5, publish PR tests 2/2, targeted strict Credo clean, `mix specs.check`, and `git diff --check` passed.
---

## 2026-06-28: Follow-up queue observability and blocker RCA [done]
- **What**: Kept the split SYM-24..31 follow-up set, then exposed Compose observability, JSM ticket preflight compatibility, dispatch blocker counts, restart claim expiry, and distinct total-token/no-diff blocker causes.
- **Why**: Live polling looked idle even though every candidate was blocked; the HTTP dashboard was bound to container loopback, SYM-31's JSM body shape was rejected, and total-token blockers were reported as no-diff.
- **Impact**: Operators can now see `running/retrying/blocked`, dispatch slots, polling state, and exact blocker cause from `127.0.0.1:4000`; restarts no longer renew dead claims indefinitely.
- **Test**: `mix format --check-formatted`, `mix test` 350/350 plus 2 skipped, `mix specs.check`, `mix squad.check`, `git diff --check`, Compose rebuild/recreate OK, API `/api/v1/state` and dashboard root returned 200.
- **Trap**: SYM-31 did dispatch after the parser fix, then correctly blocked on the 1.5M total-token guard; old comments used the no-diff marker, so the API now prefers the workpad `Type:` line to recover the true cause.
- **Next**: Narrow or retune blocked SYM-21/23/25/27/29/30/31 before clearing their runtime blocker markers; SYM-29 remains a true no-diff ticket while the others are total-token blocked.
---

## 2026-06-28: Colima disk headroom [done]
- **What**: Resized the default Colima Docker VM from 20GiB to 100GiB and restarted the Symphony compose orchestrator.
- **Test**: `colima list` reports `100GiB`; container root filesystem reports 99G size, 21G used, 74G available; `/api/v1/state` returned running 0/retrying 0/blocked 7 after restart.
---

## 2026-06-28: E2E exception handling probe [done]
- **What**: Verified live blocker/log behavior and added early runtime blockers for MCP invalid-token and insufficient-scope failures instead of letting simple e2e runs burn tokens until a budget stop.
- **Test**: exception-path tests 164/164, full `mix test` 352/352 plus 2 skipped, `mix specs.check`, `mix squad.check`, `git diff --check`, Compose rebuild/recreate, and `/api/v1/state` OK.
---

## 2026-06-28: Long-run ops preflight and queue tickets [done]
- **What**: Added dispatch-time Codex auth preflight and created SYM-32..35 for GitHub App token broker, Codex auth keeper, stateless queue mode, and MCP credential preflight.
- **Why**: Symphony's stronger orchestration still needs the AIDevSquad-style long-run pattern of short bounded work, external token brokers, explicit credential checks, and graceful blocking before expensive Codex turns.
- **Impact**: Compose now blocks stale or missing `/root/.codex/auth.json` before starting Codex and leaves the remaining long-run hardening work as dispatchable Jira tickets.
- **Test**: `mix format --check-formatted`, `git diff --check`, `mix test` 355/355 plus 2 skipped, `mix specs.check`, `mix squad.check --file docs/codex-squad-evidence.example.md --workflow WORKFLOW.md`, ticket strict checks 4/4, Compose rebuild OK, `/api/v1/state` reported running 0/retrying 0/blocked 11 with SYM-32..35 auth-preflight blocked.
- **Next**: Superseded by the writable-auth-cache follow-up below; `last_refresh` age alone is not a valid hard blocker for active Codex sessions.
---

## 2026-06-28: Writable Codex auth cache and optional MCP degrade [done]
- **What**: Changed Compose to seed host Codex auth into a writable named volume, disabled stale-age and total-token hard blocks for e2e, set one active issue, capped recovered restart claims, and stopped optional MCP noise plus squad-completion continuation loops from blocking unrelated tickets.
- **Why**: Official Codex automation guidance and AIDevSquad both favor trusted-runner credential reuse/degrade over forced relogin; live E2E proved stale `last_refresh` did not prevent Codex calls, while dirty-workspace retries and post-completion reruns inflated token totals.
- **Impact**: SYM-32..35 can run sequentially while optional Cloudflare MCP scope failures no longer stop GitHub/Codex/queue tickets; restarts no longer hold an empty active slot for 10 minutes, and completed squad runs no longer immediately rerun the same active ticket.
- **Test**: `mix format --check-formatted`, `mix test` 356/356 plus 2 skipped, targeted continuation/restart tests 113/113, `mix specs.check`, `mix squad.check --file docs/codex-squad-evidence.example.md --workflow WORKFLOW.md`, `git diff --check`, Compose rebuild/restart, marker cleanup, `/api/v1/state` showed SYM-33 running with SYM-34/SYM-35 queued after SYM-32 was removed from the e2e label.
---

## 2026-06-28: Final verifier green-check freeze [done]
- **What**: Added final-verifier and workflow handoff rules that freeze repo state after the latest PR checks are green, then rebuilt and restarted Compose.
- **Why**: SYM-33 proved recording final-head green evidence inside repo files creates a new head and retriggers checks.
- **Impact**: Future final verifiers should report volatile head/check evidence outside repo files and avoid self-invalidating CI loops.
- **Test**: `mix format --check-formatted`, `mix test test/symphony_elixir/core_test.exs` 59/59, targeted `git diff --check`, Compose build/recreate, container grep for freeze text, and `/api/v1/state` showed SYM-33 cleared with PR #28 still green at `d7171e3`.
- **Trap**: Restart redispatched SYM-33 because Jira lacked `Human Review`; moved it to terminal `해결됨` after confirming available transitions.
---

## 2026-06-28: Squad completion flow hardening [done]
- **What**: Added a spec and hardened squad completion so normal exits run publish hooks strictly, SYM workflow handoff uses reachable success terminal states and PR-base sync, green evidence-only publish is frozen, and verifier FAIL reasons surface in blockers.
- **Why**: SYM-33/SYM-35 showed prompt-only handoff could self-trigger CI loops, miss after-complete handoff guarantees, and hide the actual verifier failure behind mechanical PASS-row errors.
- **Impact**: Compose squad runs now avoid post-green evidence commits, fail visibly when publish handoff fails, and no longer instruct agents to use unavailable SYM `Human Review` success transitions.
- **Test**: Targeted ExUnit 64/64, full `mix test` 362/362 plus 2 skipped, `mix format --check-formatted`, `mix specs.check`, `mix squad.check`, `git diff --check`, Compose build/recreate, container grep for hardening text, and `/api/v1/state` stayed running/blocked/queued 0 after one poll.
- **Trap**: SYM-35 was moved to `Pending` before restart so the cleared in-memory blocker would not redispatch and burn tokens.
---
