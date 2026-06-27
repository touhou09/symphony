## 2026-06-26: Codex squad mode and Compose deployment [done]
- **What**: Added configurable Codex squad role routing, evidence gate, headless Docker Compose orchestrator deployment path, and Jira endpoint validation.
- **Why**: Keep GPT-5.5 responsible for scope/final judgment while using GPT-5.3 Codex Spark for bounded implementation and requiring GPT-5.4 plus GPT-5.5 verifier passes before handoff.
- **Impact**: Symphony operators can run the orchestrator through Compose without exposing the UI and enforce a visible cross-model evidence packet before review/deploy.
- **Test**: `mix format --check-formatted`, targeted ExUnit 53/53, `mix squad.check`, `docker compose build orchestrator`, headless Docker smoke without exposed ports, Jira/config regression tests 81/81, and Compose config succeeded.
- **Trap**: Initial Compose build hit Colima disk pressure while exporting the Codex npm layer; pruning Docker build cache recovered enough space and the same image build then completed.
- **Next**: Real Jira polling requires `.env` values for `JIRA_ENDPOINT`, `JIRA_API_TOKEN`, `JIRA_EMAIL`, and the Jira project key in `WORKFLOW.md`; smoke deployment intentionally used no committed secrets.
---

## 2026-06-26: Jira SYM live smoke and status-id polling [done]
- **What**: Persisted local ignored Jira env, switched the sample workflow to SYM/Jira, and added Jira status ID filters for polling while preserving status names for orchestration and transitions.
- **Why**: Jira Cloud returned zero results for localized status-name JQL (`미해결`) but returned the same issue by status ID, so candidate polling needed an ID-backed path for Korean service desk projects.
- **Impact**: Symphony can authenticate to `yujin3178.atlassian.net`, poll SYM candidates, write comments, and transition Jira issues without relying on public project access.
- **Test**: Relevant ExUnit 91/91, live smoke created `SYM-1`/`SYM-2`/`SYM-3`, verified read/comment/transition, and confirmed all smoke issues ended in `완료` with candidate queue back to 0.
- **Trap**: YAML frontmatter could not parse raw Korean state names in this setup; keeping names as `\uXXXX` escapes preserved parsed Korean values while making the file parser-safe.
---

## 2026-06-26: Jira-backed full-flow E2E smoke [done]
- **What**: Ran a bounded full orchestration smoke using an ignored temp workflow and fake Codex app-server against real Jira `SYM` issue `SYM-4`.
- **Why**: Separate tracker-level live smoke from the end-to-end Symphony loop: Jira poll, workspace creation, app-server session/turn, Jira comment, terminal transition, retry cleanup, and dashboard state.
- **Impact**: The Jira/SYM pipeline is verified through the orchestrator without spending model tokens or letting a real unattended model modify code during smoke.
- **Test**: `SYM-4` dispatched, workspace files were created under `/private/tmp/symphony-full-e2e-workspaces/SYM-4`, fake app-server completed one turn, Jira state ended as `완료`, and final snapshot showed running/blocked/retrying all empty.
- **Next**: A separate real-Codex E2E would validate model behavior and prompt compliance; this smoke validates the Symphony plumbing and Jira integration.
---

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

## 2026-06-27: Local autostart recovery [done]
- **What**: Added login-time recovery so Colima starts first and the headless Symphony orchestrator is reconciled into a running Compose service.
- **Why**: The Mac should recover Tailscale and Symphony after power or login cycles without manually replaying the setup commands.
- **Impact**: Local SYM orchestration resumes on this Mac after login, with Docker keeping the orchestrator alive unless it is explicitly stopped.
- **Test**: LaunchAgent enabled and run exit code 0, Colima running, `docker compose ps` showed `symphony-orchestrator-1` Up, and Tailscale status returned `100.66.205.12`.
---

## 2026-06-27: Fork source deployment wiring [done]
- **What**: Pointed the local Compose deployment at the `touhou09/symphony` fork and made workspace bootstrap honor an explicit source branch.
- **Why**: Using only the fork URL would still clone the default branch, so Jira workspaces needed branch-aware cloning to run the active adapter branch.
- **Impact**: New workspaces after the next orchestrator recreate clone `feat/jira-tracker-adapter` from the fork instead of upstream `openai/symphony`.
- **Test**: Compose config resolved `SYMPHONY_SOURCE_REPO=https://github.com/touhou09/symphony` and `SYMPHONY_SOURCE_BRANCH=feat/jira-tracker-adapter`; running container was intentionally left untouched while active agents continue.
---

## 2026-06-27: Fork image redeploy [done]
- **What**: Captured active SYM-6/SYM-11 workspace diffs, rebuilt the orchestrator image from the local fork checkout, force-recreated the Compose service, and retargeted existing workspaces to the fork remote.
- **Why**: Env-only recreate made future clones fork-aware, but a real fork deployment also needed the container image rebuilt and existing active workspaces moved off the upstream remote.
- **Impact**: The running orchestrator now uses the fork repo/branch settings while interrupted active Jira work was restarted against preserved workspaces.
- **Test**: `docker compose build orchestrator` succeeded, `docker compose up -d --force-recreate orchestrator` started, container env reports `touhou09/symphony` and `feat/jira-tracker-adapter`, restart policy is `unless-stopped`, and SYM-6/SYM-11 diffs remained present.
---

## 2026-06-27: Completion PR publish hook [done]
- **What**: Added a workspace completion hook that commits, pushes, and opens or discovers a GitHub PR after Symphony work leaves active execution.
- **Why**: Finished Jira work must leave a reviewable branch/PR even when the unattended agent exits before manually attaching one.
- **Impact**: Completed fork workspaces now publish against `touhou09/symphony` with base `feat/jira-tracker-adapter`; SYM-6 and SYM-11 were published as PR #1 and #2.
- **Test**: `mix format`, targeted ExUnit 65/65, `git push` for both workspace branches, and GitHub PR lookup confirmed both PRs open.
---
