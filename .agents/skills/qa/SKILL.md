---
name: qa
description: Hunt the defects the e2e suite cannot see — resource accumulation, leaks, and degradation on the long-lived installed build, plus a live agent-orchestration pass driving the real claude, codex, and opencode CLIs through the real hook chain. Use when asked to stress test, soak test, profile CPU or memory, hunt performance regressions or leaks, exercise agent orchestration against real agents, or QA the real installed app.
---

# QA sweep of the live Spaces build

**This exists to catch what e2e cannot.** The e2e suite asserts known invariants, on a clean profile, in a single short pass. It is the right tool for correctness and it is already extensive — running it, and reading its latency lanes, is the **`e2e` skill's** job, not this one (§10). It is structurally blind to a specific class of defect, and that class is this skill's entire job.

The one deliberate exception is agent orchestration (§5): it is exercised here as a full feature pass against the real coding-agent CLIs, overlapping the e2e lane on purpose, because the live path has repeatedly failed where the lane stayed green.

Measure the running build. Source explains *why* a number is what it is; it never establishes *that* it is.

## What e2e cannot see, and this sweep can

Every defect worth reporting here lives in one of these blind spots. If a finding does not, it belongs in e2e instead.

1. **Cost that accumulates rather than fails.** A leak of a couple of file descriptors per session keeps every assertion green. Only a slope fitted across many sessions exposes it.
2. **State on a long-lived profile.** e2e starts clean each run. A real profile carries months of rows, files, and sockets, and per-row costs are paid against *that*. Findings here scale with history the suite never has.
3. **Configurations e2e never runs in.** The installed build under launchd, against the real `~/.spaces` profile, with a phone actually paired, with real coding agents talking to real models.
4. **Tail behaviour and degradation over time.** e2e measures one pass. A p90 that collapses only under sustained load, or a cost that grows over an hour, is invisible to it.
5. **Unknown unknowns.** Nobody wrote an assertion for it because nobody knew to. Exploration produces findings; e2e produces pass/fail.

## Ground rules

1. **Target the installed build**: `/Applications/Spaces.app/Contents/MacOS/SpacesApp`, `~/.spaces/bin/spacesd`, and the app's `caddy`. Match daemons with an anchored pattern (`pgrep -f "^$HOME/.spaces/bin/spacesd"`) so other worktrees' daemons never match. Never kill them.
2. **Establish what you are testing.** Compare the installed binary against the repo: `git log --oneline HEAD..v<version>` and `HEAD..origin/main`. The installed build can be *ahead* of your checkout, not only behind. Confirm each finding's code path still exists at `HEAD`.
3. **Never create projects or workspaces.** `spaces workspace` exposes only list/create/start/restart and `spaces project` only `list` — there is no stop, remove, delete, or archive. A workspace created here cannot be removed programmatically and permanently pollutes the user's list. Do lifecycle work on a disposable dev profile.
4. **Every load generator is deadline-bound and self-terminating** — bound by volume (`head -c N`) or an internal deadline (`end=$((SECONDS+N))`). Never background an unbounded `yes`/`while true`.
5. **Snapshot before, verify after.** Record project ids, workspace ids, `git worktree list`, and the live session list up front; `diff` each at the end and show the empty diffs.
6. **Keep raw artifacts in the scratchpad**, and never read a full `sample` transcript into context — `grep`/`awk` it.

## 0. Run the e2e and latency suites first

Do this before any measurement, and run it through the **`e2e` skill** — that skill owns lane selection,
the environment states that make a lane fail misleadingly, and the flake-versus-regression call (§10).
It is a gate, not correctness re-testing (§9): a sweep run on a build whose suite is red measures sand,
and the suite itself rots silently because these lanes are manual and outside CI.

Abort the sweep rather than recording results if the gate does not come back clean.

## 1. Baseline

Capture idle CPU, RSS, threads, fds, and DB size for app, daemon, and caddy, plus one `sample <pid> 10` of each. In a `sample`, ignore idle-wait leaves (`kevent64`, `__workq_kernreturn`, `mach_msg2_trap`, `__psynch_cvwait`, `__ulock_wait2`) — blocked threads, not CPU.

Inventory the database *before* loading it: row counts per table, and `SELECT name, SUM(pgsize)/1024 FROM dbstat GROUP BY name ORDER BY 2 DESC`. A table holding most of the file with few live rows is blind spot #2 made visible, and is a finding on its own.

**Check for a live device subscriber first** (§4). It can dominate the idle baseline, and a baseline taken without one is not comparable to a measurement taken with one.

## 2. Scale one dimension and report the slope

The highest-yield technique here, and the one that turns accumulation into a filed issue.

Hold everything constant, vary **one** quantity (live sessions, output volume, rows in a table, open panes), take three or more points, and report the **slope**. A clean linear fit is the strongest evidence available and predicts cost at scales you never ran. Measure per window: CPU-seconds delta (from `ps -o time=`, never `%cpu`), WAL bytes, RSS, threads, fds.

Idle sessions are the sharpest probe — a session running `sleep` does no work, so anything scaling with it is pure overhead.

**Find the mechanism at the extreme; judge severity at a realistic rate.** A saturating generator locates a bottleneck and finds the ceiling, but is the wrong basis for severity. Always measure both and label which produced each number: pathological (output as fast as the pty accepts) versus realistic (what a verbose build actually emits — hundreds of KB/s across a few panes, throttled with a `sleep` in the generator loop). This changes conclusions, not just numbers: typing latency beside a saturating producer showed an alarming p90, while the same measurement across many panes at a build-like rate was indistinguishable from idle. The honest finding was a ceiling a runaway process can hit, not something users feel.

**Report the tail, not the mean.** Head-of-line blocking leaves the median untouched while the p90 collapses; a mean-only measurement reports "no problem" for a real stall.

## 3. Profile and read memory correctly

At the highest load point, `sample` the daemon and attribute non-idle frames to app symbols. Two signatures worth knowing:

- More CPU in `sqlite3RunParser` / `yy_reduce` / `sqlite3GetToken` than in `sqlite3VdbeExec` means statements are re-prepared on fresh connections rather than executed — look for a connection opened per call. Accompanying `__getattrlist`/`stat`/`__open_nocancel`/`__fcntl` means per-row path resolution.
- Heavy `_swift_getGenericMetadata` / `swift_retain` / `swift_release` means generic code in a hot loop; attribute it to the app frame directly above.

Read memory with `vmmap --summary <pid>`, not `ps` RSS alone — they disagree substantially. `Physical footprint` is what macOS charges; `(peak)` gives the high-water you would otherwise miss. Regions marked `(empty)` are freed to the allocator but not returned to the OS: allocator high-water, **not** a leak. Break out `IOAccelerator` separately — GPU memory does not appear where you expect. Compare a region against its own pre-test value before calling it retained.

## 4. Configurations e2e never runs in

- **A paired device is a live overview subscriber**, and it is the most valuable probe in the sweep. With one attached and *zero* terminal sessions open, the daemon does continuous overview-rebuild work that can dominate the idle baseline. Detect it with `lsof -nP -p <daemon> | grep ESTABLISHED` on port 47847, and always state whether one was attached.
  Scope limit: `spaces device list` shows **outbound** targets only; inbound clients live in `~/.spaces/runtime/terminal/device-pairings.json`. `--device <iphone>` does not work — the phone is a client, not a target. Test the daemon side of what it asks for; its UI is manual verification.
- **Real coding agents against real models** — cost and nondeterminism keep these out of CI. As a load source, launch them in panes with output-heavy prompts; as a feature under test, run the full pass in §5. Either way use cheap models and read-only flags so an unattended run cannot modify the repo.
- **Live Ghostty panes.** A headless daemon session exercises no render, attach, or ownership path. Open panes with `spaces terminal show` and measure cold (first surface) against warm (surface exists) separately. Note that `terminal show` on a session with no pane creates no attachment, so ownership assertions are vacuously true without one.
- **Energy.** `powermetrics` needs a sudo password and will block an unattended run; reach for it only when the user is present. The non-sudo proxy is `psutil.Process(pid).cpu_times()` and `.num_ctx_switches()` — context switches *are* available on macOS. Report the wakeup rate next to CPU%: a low-CPU, high-wakeup process still drains battery.

Two resilience checks belong here rather than in a lane, because they depend on the installed configuration and e2e runs neither under launchd nor against the real profile:

- **SIGKILL the daemon.** launchd restarts it within seconds under a new pid — do not conclude it is gone without waiting. Sessions cannot survive (pty master fds die with the process); that is inherent. Assert instead that every profile-owned row moved `running` → `failed` with its dead `child_pid` retained. Rows still claiming `running` afterwards are rows the repair cannot see, which is a real finding.
- **Hold the DB write lock** from a separate connection. Within the 5 s busy timeout nothing is disturbed; past it, reads still succeed (WAL) but a CLI write blocks on an RPC timeout far longer and fails with an opaque "Resource temporarily unavailable".

If you must validate migrations against a *real* user database, work on a copy: `.backup` it (WAL-aware; plain `cp` can miss un-checkpointed commits), step `migration_state` back **one** version, and open it under both `SPACES_DB_PATH` and `SPACES_RUNTIME_DIR` pointing at scratch. **That spawns a daemon for the scratch profile which outlives the command** — sweep it afterwards. Stepping back further than one version does not replay the chain; use a unit test against a genuinely old fixture for that.

## 5. Agent orchestration against the real agents

Run this every sweep. It is a **full feature pass**, not a resource measurement, and it deliberately overlaps `e2e_agent_orchestration.sh`: that lane proves the mechanics on a clean dev profile, while almost every orchestration defect actually seen came from the live path it cannot reach — a hook whose absolute path points at the wrong build, a TUI that swallowed a submit, a provider that never emits the event the design assumed, an installed profile whose hooks were clobbered by a dev build's installer.

Exercise all three supported agents — **Claude Code, Codex, opencode** — as a user runs them, from the installed profile.

**Cost and safety.** Cheap models and read-only flags throughout: `claude --model haiku --permission-mode plan`, `codex -m gpt-5.3-codex-spark --sandbox read-only --ask-for-approval never`, opencode on its cheapest configured model. Ground rule 3 still holds — use an **existing** workspace. Agents here create terminal sessions and agent rows, both removable; never a project or workspace. Claude Code's status line shows the configured default model even under `--model haiku`, so confirm the model with `ps` on the child, not the TUI.

### 5.1 Verify the hook chain first

Every conclusion below depends on it, and it fails **silently**: each hook command carries the absolute path of whichever build installed it and ends in `>/dev/null 2>&1 || true`.

- `grep spaces-agent-hook ~/.claude/settings.json ~/.codex/hooks.json ~/.config/opencode/plugin/spaces-agent-signal.js` — confirm the path is the installed CLI and the trailing `v<N>` matches the hook version this build writes.
- Codex needs `features.hooks = true` in `~/.codex/config.toml` and gates any hook change behind an interactive trust review; the first session after an install fires nothing until "Trust all" is picked (`[hooks.state] trusted_hash`).
- Prove one signal by hand before trusting anything else: `spaces agent signal working` inside a Spaces session, and watch the row move. `status=idle signaled=false` on a visibly working agent means a broken chain, not a classifier bug.
- Provider asymmetry is expected, not a finding: Claude Code reports session end; Codex and opencode do not. Codex's TUI emits no SessionStart — its first signal is `working` at the first prompt submission.
- Check the reported install state against reality too: Settings → Coding Agents (and the launch setup step) must call an agent out of date when its entries are stale or, for Codex, when `features.hooks` is off. Reinstalling must replace Spaces' entries, never accumulate one per release, and must write through a dotfiles symlink rather than replacing it.

### 5.2 Spawn and prompt delivery

`spaces agent spawn --command` runs without the login shell's environment, so a version-manager-installed agent (`codex` behind fnm) is not found, and wrapping in `sh -c` is rejected by the command validator. Exercise **both** routes and record both:

- `spaces agent spawn --command <agent> --json` where the binary resolves at a stable path (claude), including the failure shape: a command that is not a supported agent must fail loudly, and a never-detected agent must exit non-zero, name what it waited for, and leave the session running.
- The user's route: `terminal command` → `terminal show` → `terminal send text <sid> '<cmd>' --submit`.

Per provider, confirm that `--submit` actually **ran** the line rather than leaving it in the composer, and note whether a first-run state (trust review, onboarding, auth) swallowed the prompt. Repeat one submit with the pane never opened, to confirm delivery does not depend on a live surface.

### 5.3 Scenarios worth running

Vary the shape of the work, not just the provider. Each of these exercises a distinct transition:

- **Single-turn, no tools** — the shortest `working` → `done`. An agent that lands in `idle` here has a hook gap.
- **Tool-heavy multi-turn** (read several files, then summarize) — exercises the per-tool `working` signal and its duplicate suppression: repeated `working` must add no lifecycle events and must not refresh the row's updated time, which keeps marking when the agent entered its current status.
- **A prompt that blocks on permission** — run the child *without* a yolo flag so it genuinely asks. Blocked → approve → working is the only path that proves the post-approval tool-use signal, since the approval itself fires no hook.
- **Three teardown paths, three different rows**: the child exiting on its own, `spaces agent kill <session>`, and the pane closed underneath it. `kill` must refuse a plain shell or process terminal with "no agent session".
- **Fan-out**: one orchestrator, one child per provider, all subscribed; then answer them out of order.
- **Orchestrator busy while a child transitions** — the block must be held and land at the subscriber's next idle, and a held event must also ride out on the next `spaces_*` MCP tool result as `pendingAgentEvents`, delivered exactly once by whichever path reaches it first.
- **Blocked-then-resumed while the subscriber is busy** — the held blocked line must be withdrawn, not delivered late. A held `done`/`exited` is a terminal fact and must still arrive.
- **Rejections must fail loudly**: subscribing to a terminal whose agent has never signaled, subscribing to itself, and a two-terminal cycle.
- **Ad-hoc rows**: an agent started by hand in a plain terminal, established by its first signal, must stay in Coding Agents for the life of that session, and a later `init` in the same terminal must reset an exited row to idle.
- **Injected block shape**: `[spaces] <label> (<kind>) is <blocked|done|exited>` followed by indented `project`/`workspace`/`branch`/`session`/`note`/`link` lines, with the workspace as a full path and no imperative wording.
- **Cross-device**, when the remote is configured (source `scripts/spaces-e2e-env.sh`): remote spawn with `--workspace`, cross-device subscribe, delivery of the child's transitions onto the local orchestrator, offline unsubscribe, and the device-qualified deep link.

The orchestrator must itself be a coding agent. A plain shell subscriber executes the injected block and reports a shell syntax error — that is injection working, not a defect.

### 5.4 What to measure here

Report these in the measurements table alongside the resource numbers: spawn → detection per provider (cold and warm); signal → visible in `spaces agent list --json`; child transition → block submitted in an idle subscriber, and the held-then-released variant; the same transition → delivery number over a cross-device watch next to its local counterpart; and daemon CPU-seconds and RSS per additional live agent and watch edge, scaled as a slope per §2 rather than a single pair.

## 6. Leak checks

For file descriptors, threads, DB rows, and on-disk directories: sample the count at several points with the *same* number of live sessions, and fit a line against sessions **created**. A clean fit across three or more points is proof; a single before/after pair is not — that is exactly the shape e2e already covers and misses.

Distinguish "held open" from "still on disk": `lsof` the paths and test each with `[ -e ]`. A descriptor whose file is already unlinked is unambiguous. Let the process settle for several minutes before declaring memory retained.

## 7. Soak

Run a realistic mixed workload for 30+ minutes: long-lived sessions producing output, periodic reads, session churn, and repeated bursts of whatever interaction you are testing. Sample every 5–10 s to CSV with `sampler.sh`.

Look for **drift and degradation**, not absolute values: does RSS trend up after warm-up, does DB size grow, and is a repeated operation as cheap in the last burst as the first? Identical cost across many bursts is a strong negative result worth reporting.

## 8. Prove it, or drop it

Most of the value is here. A plausible mechanism is not a finding.

1. **Run the control.** Before attributing a cost to X, build the same workload without X. Process churn was once blamed for a large CPU cost until fork-heavy and fork-free workloads of equal byte volume measured the same.
2. **Warm the cache and repeat the operation.** A benchmark that never repeats measures cache-miss cost, not the steady state. Probing unique non-existent filenames against a cold directory once overstated a penalty by more than an order of magnitude; warmed and repeated, the effect nearly vanished.
3. **Ask whether a clean install would hit this.** A dev machine carries many profiles, stale global config, and test residue. If the mechanism needs any of that, it is an environment artifact — say so and do not file it.
4. **Check the docs before calling something a bug.** `docs/spec.md` may define the behaviour deliberately. If the user disagrees with documented behaviour, raise the conflict rather than silently changing course.
5. **Correct yourself in place.** When a measurement is refuted, amend the issue and tell the user plainly.

Delegate each surviving finding to a subagent for root-cause analysis against the source, giving it the numbers. Require file:line evidence and treat its conclusions as claims to verify.

## 9. Triage, then offer to file

Build the table before filing anything: probability, impact 1–10, effort to write a failing test (with reason), recommendation. Real frequency with real impact, and trivial correctness fixes, are worth filing; prefer an issue over a fix for low-impact findings needing disproportionate complexity; anything irrelevant to product UX is accepted risk, recorded so it does not resurface.

**Do not file unprompted.** Present the report (§12) with the triage table, say which findings you would file and why, and open issues once the user says to. Search open **and** closed issues before filing.

Each issue must be reproducible from its own text: the measurement table, the mechanism with file:line anchors, ranked fixes with risks, and the test that would prove the fix. **If that test is a deterministic assertion, say so and point at the e2e lane it belongs in** — the sweep's output should feed the suite, so the same defect is caught automatically next time.

## 10. Stay out of e2e's lane

The suite already asserts the correctness invariants, and the **`e2e` skill** owns running it, its latency lanes, and the flake-versus-regression judgement. Re-running a lane here is duplicated effort, and asserting a lane's invariant by hand is worse than the automated version. Touch an e2e-covered behaviour only when *measuring resource behaviour* rather than checking correctness.

The single exception is agent orchestration: §5 re-tests it on purpose, because `e2e_agent_orchestration.sh` runs the mechanics on a clean dev profile while the live pass runs the real agent CLIs, the real global hook configuration, and real models. Duplication there is the point; everywhere else it is waste.

Corollary: **anything that reduces to a deterministic pass/fail belongs in e2e, not here.** If this sweep finds such a defect, report it *and* name the lane that should have caught it.

## 11. Clean up

1. Close every session you created; intersect against the live list and preserve everything else.
2. An agent TUI ignores `exit` and `Ctrl-D` — end children with `spaces agent kill <session>`, or terminate the agent process directly, then exit the shell.
3. Remove every watch edge you created (`spaces agent unsubscribe`), including cross-device ones, so no orchestrator keeps receiving lines from the sweep.
4. Leave the user's hook configuration exactly as you found it. If the sweep repaired or reinstalled hooks, say so in the report.
5. Sweep for stray daemons bound to scratch runtime dirs, and for leaked generators by pattern.
6. `diff` project ids, workspace ids, and `git worktree list` against the opening snapshot; show the empty diffs.
7. Re-measure the settled baseline against the starting one. Anything that did not return is either a finding or an explicit non-finding.

## 12. Report

Close the sweep with a **brief** report — findings, not a narrative of what you ran.

1. **What was measured**: the installed version under test, whether a device subscriber was attached, which agents and models the orchestration pass used, and total soak duration. Two or three lines.
2. **Findings**, most severe first, one short paragraph each: what happens, the evidence, and the mechanism if it is known. State strong negative results too — "the same operation cost the same in the last burst as the first" is a finding worth writing down.
3. **Measurements table**, one row per metric:

   | Metric | Baseline | Under load | Delta | Note |
   |---|---|---|---|---|

   Give units and the condition each number was taken under (pathological versus realistic, cold versus warm, per §2). Use the Note column only where an observation triggered an investigation, and say how it landed — including the ones that came back negative, since a refuted hypothesis is what stops it being re-chased next sweep.
4. **Triage table** from §9, with the findings you would file and the ones you would record as accepted risk.
5. **Offer to file.** Do not open issues until the user agrees.
