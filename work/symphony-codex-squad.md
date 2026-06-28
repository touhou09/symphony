## 2026-06-26: SYM Jira ticket form constraints [done]
- **What**: Queried SYM Jira project metadata, JSM request types, request form fields, issue create metadata, and validated one JSM request creation path.
- **Why**: A reusable ticket skill needs to choose between JSM request forms and raw Jira issue creation; their required fields and description formats differ.
- **Impact**: Agents can create SYM tickets without guessing request type IDs, required fields, status IDs, or localized JQL behavior.
- **Test**: JSM request type 9 created `SYM-5` through `/rest/servicedeskapi/request`; it was then transitioned to a done-category state, and no token values were written to tracked files.
- **Next**: Encode the request type table, status IDs, and API choice rules into a `sym-jira-ticket` Codex skill.
---

## 2026-06-27: Ticket preflight and SYM Jira skill guardrails [done]
- **What**: Added ticket-body preflight, `mix ticket.check`, SYM workflow enforcement, Jira success-transition preference, a durable modification spec, and the local `sym-jira-ticket` Codex skill.
- **Why**: Symphony needs to reject underspecified tickets before unattended Codex dispatch while keeping verifier evidence as a separate handoff gate.
- **Impact**: SYM tickets now need structured Background/Scope/Acceptance Criteria/Validation checklists before dispatch; generic successful completion prefers `해결됨`/`완료` over `취소`.
- **Test**: Targeted ExUnit 28/28, in-repo WORKFLOW render 1/1, `mix format --check-formatted`, `mix ticket.check` positive OK, malformed ticket negative failed with 3 errors, `mix squad.check` OK, and skill script preflight OK.
- **Next**: Implement phase-2 true multi-model Codex role orchestration; current role separation is still enforced through evidence, not separate model process execution.
---

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

## 2026-06-27: Restart recovery and SYM-6 ticket split smoke [done]
- **What**: Verified Compose restart recovery against the persisted SYM-6 runtime blocker and split the broad SYM-6 scope into four bounded Jira tickets: SYM-7, SYM-8, SYM-9, and SYM-10.
- **Why**: The broad parent ticket was too large for unattended Codex and restart recovery needed proof that persisted tracker state prevents repeat dispatch/token burn.
- **Impact**: SYM-6 remains blocked by marker, while the split tickets are preflight-valid active candidates for smaller Symphony runs.
- **Test**: Candidate queue before restart was 1, Compose restart logged `runtime blocker persisted`, active agents/tokens stayed at 0, split ticket bodies passed Python and `mix ticket.check`, fetched Jira descriptions passed Symphony preflight, and candidate queue became 5.
- **Next**: Run split tickets selectively; SYM-10 should be the first real diff-producing E2E smoke after choosing an isolated tiny change.
---

## 2026-06-27: E2E dispatch unblocked and Compose started [in-progress]
- **What**: Removed the persisted SYM-6 no-diff runtime blocker marker and started the Docker Compose orchestrator for a live E2E run.
- **Why**: The user requested marker removal and a real E2E dispatch opportunity after split-ticket validation.
- **Impact**: SYM-6 and split tickets SYM-7 through SYM-10 are running concurrently under the configured max concurrency.
- **Test**: SYM-6 preflight returned OK after marker removal; Compose status shows orchestrator up; dashboard/log tail shows 5 active agents with token accounting active.
- **Next**: Monitor workspaces/Jira workpads for diff, evidence, verifier PASS, no-diff blockers, or terminal transitions.
---

## 2026-06-27: No-diff execution loop fix ticket [done]
- **What**: Created SYM-11 to track the fix for bounded Codex tickets dispatching but producing no workspace diff before the no-diff guard blocks them.
- **Why**: SYM-6 through SYM-10 all proved the same workpad-only/no-diff failure mode, so retries should be blocked until the prompt/runtime contract is fixed.
- **Impact**: Future E2E runs have a dedicated remediation ticket instead of repeatedly burning tokens on active implementation tickets.
- **Test**: Stopped Compose first, `mix ticket.check` passed for the new ticket body, Jira create returned SYM-11 with `Relates` link to SYM-6, parent comment succeeded, fetched Jira preflight returned OK, and Compose remained stopped.
- **Trap**: The Python skill validator hung on this longer body, while the repo checker and fetched Jira preflight both passed; treat that validator hang as a tooling follow-up if it recurs.
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

## 2026-06-28: Total token budget blocker [in-progress]
- **What**: Added a configurable `codex.max_total_tokens` guard and set the Compose workflow default to 1,500,000 tokens per running issue.
- **Why**: Live SYM-23 e2e proved auth was fixed but a diff-producing role could still climb past 6M tokens, bypassing the no-diff guard.
- **Impact**: Future runaway issues stop as runtime blockers even when workspace diffs exist, preserving the Jira workpad evidence and active slot state.
- **Test**: `mix format --check-formatted`, `mix test` targeted 54/54, total-limit test 1/1, `orchestrator_status_test` 51/51, `workspace_and_config_test` 53/53, `mix specs.check`, `mix dialyzer --format short`, and lib-only strict Credo passed.
- **Trap**: Local strict Credo still crashes on existing test sigils under Elixir 1.20.1; CI uses Elixir 1.19.5 for the full check.
- **Next**: Merge to dev/main, redeploy, and verify SYM-21/SYM-23 are blocked or resumed under the new budget.
---
