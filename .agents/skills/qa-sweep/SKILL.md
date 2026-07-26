---
name: qa-sweep
description: Hunt the defects the e2e suite cannot see — resource accumulation, leaks, and degradation on the long-lived installed build, measured by stress and soak testing rather than pass/fail assertions. Use when asked to stress test, soak test, profile CPU or memory, hunt performance regressions or leaks, or QA the real installed app.
---

# QA sweep of the live Spaces build

**This exists to catch what e2e cannot.** The e2e suite asserts known invariants, on a clean profile, in a single short pass. It is the right tool for correctness and it is already extensive (see §9). It is structurally blind to a specific class of defect, and that class is this skill's entire job.

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
- **Real coding agents against real models** — cost and nondeterminism keep these out of CI. Launch `codex`, `claude`, and `opencode` in panes with output-heavy prompts, using cheap models and read-only flags (`--sandbox read-only`, `--permission-mode plan`) so an unattended soak cannot modify the repo. `spaces agent spawn --command` does not inherit the login shell's `PATH`, so a version-manager-installed agent is not found; start them as a user does (`terminal command` → `terminal show` → `terminal send text '<cmd>' --submit`).
  If every agent reads `idle signaled=false` while visibly working, the **hook chain** is broken before you conclude anything about the classifier — hook commands end in `>/dev/null 2>&1 || true`, so a wrong `spaces` path fails silently. Check `~/.codex/hooks.json`, `~/.claude/settings.json`, `~/.config/opencode/plugin/spaces-agent-signal.js`.
- **Live Ghostty panes.** A headless daemon session exercises no render, attach, or ownership path. Open panes with `spaces terminal show` and measure cold (first surface) against warm (surface exists) separately. Note that `terminal show` on a session with no pane creates no attachment, so ownership assertions are vacuously true without one.
- **Energy.** `powermetrics` needs a sudo password and will block an unattended run; reach for it only when the user is present. The non-sudo proxy is `psutil.Process(pid).cpu_times()` and `.num_ctx_switches()` — context switches *are* available on macOS. Report the wakeup rate next to CPU%: a low-CPU, high-wakeup process still drains battery.

## 5. Leak checks

For file descriptors, threads, DB rows, and on-disk directories: sample the count at several points with the *same* number of live sessions, and fit a line against sessions **created**. A clean fit across three or more points is proof; a single before/after pair is not — that is exactly the shape e2e already covers and misses.

Distinguish "held open" from "still on disk": `lsof` the paths and test each with `[ -e ]`. A descriptor whose file is already unlinked is unambiguous. Let the process settle for several minutes before declaring memory retained.

## 6. Soak

Run a realistic mixed workload for 30+ minutes: long-lived sessions producing output, periodic reads, session churn, and repeated bursts of whatever interaction you are testing. Sample every 5–10 s to CSV with `sampler.sh`.

Look for **drift and degradation**, not absolute values: does RSS trend up after warm-up, does DB size grow, and is a repeated operation as cheap in the last burst as the first? Identical cost across many bursts is a strong negative result worth reporting.

## 7. Prove it, or drop it

Most of the value is here. A plausible mechanism is not a finding.

1. **Run the control.** Before attributing a cost to X, build the same workload without X. Process churn was once blamed for a large CPU cost until fork-heavy and fork-free workloads of equal byte volume measured the same.
2. **Warm the cache and repeat the operation.** A benchmark that never repeats measures cache-miss cost, not the steady state. Probing unique non-existent filenames against a cold directory once overstated a penalty by more than an order of magnitude; warmed and repeated, the effect nearly vanished.
3. **Ask whether a clean install would hit this.** A dev machine carries many profiles, stale global config, and test residue. If the mechanism needs any of that, it is an environment artifact — say so and do not file it.
4. **Check the docs before calling something a bug.** `docs/spec.md` may define the behaviour deliberately. If the user disagrees with documented behaviour, raise the conflict rather than silently changing course.
5. **Correct yourself in place.** When a measurement is refuted, amend the issue and tell the user plainly.

Delegate each surviving finding to a subagent for root-cause analysis against the source, giving it the numbers. Require file:line evidence and treat its conclusions as claims to verify.

## 8. Triage and file

Build the table before filing: probability, impact 1–10, effort to write a failing test (with reason), recommendation. File for defects at real frequency with real impact and for trivial correctness fixes; prefer an issue over a fix for low-impact findings needing disproportionate complexity; document as accepted risk anything irrelevant to product UX.

Each issue must be reproducible from its own text: the measurement table, the mechanism with file:line anchors, ranked fixes with risks, and the test that would prove the fix. **If that test is a deterministic assertion, say so and point at the e2e lane it belongs in** — the sweep's output should feed the suite, so the same defect is caught automatically next time.

Search open **and** closed issues first.

## 9. Do not re-test what e2e already asserts

These have existing lanes in `apps/macos/Tests/`. Re-running them here is duplicated effort, and asserting them by hand is worse than the automated version. Touch them only when *measuring resource behaviour* rather than checking correctness.

`e2e_agent_orchestration.sh` (agent lifecycle and signal transitions) · `e2e_daemon_exec_handoff.sh` (handoff with live sessions) · `e2e_daemon_idle_shutdown.sh` · `e2e_terminal_latency.sh`, `e2e_mobile_latency.sh`, `e2e_remote_terminal_latency_compare.sh` (latency regression gating) · `e2e_terminal_ended_session_scroll.sh` (ended-session replay) · `e2e_terminal_edit_shortcuts.sh`, `e2e_terminal_mouse_reporting_scroll.sh` (input fidelity) · `e2e_terminal_cli_commands.sh` · `e2e_local_device_api.sh`, `e2e_remote_device_api.sh`, `e2e_remote_terminal_send.sh` · `e2e_macos_app.sh`, `e2e_mobile.sh` · `e2e_fixture_repos.sh`. Migrations, themes, deep links, restore, and automations have unit/integration coverage.

Corollary: **anything that reduces to a deterministic pass/fail belongs in e2e, not here.** If this sweep finds such a defect, file it *and* note the lane that should have caught it.

The two resilience checks worth doing by hand are the ones that depend on the installed configuration, because e2e runs neither under launchd nor against the real profile:

- **SIGKILL the daemon.** launchd restarts it within seconds under a new pid — do not conclude it is gone without waiting. Sessions cannot survive (pty master fds die with the process); that is inherent. Assert instead that every profile-owned row moved `running` → `failed` with its dead `child_pid` retained. Rows still claiming `running` afterwards are rows the repair cannot see, which is a real finding.
- **Hold the DB write lock** from a separate connection. Within the 5 s busy timeout nothing is disturbed; past it, reads still succeed (WAL) but a CLI write blocks on an RPC timeout far longer and fails with an opaque "Resource temporarily unavailable".

If you must validate migrations against a *real* user database, work on a copy: `.backup` it (WAL-aware; plain `cp` can miss un-checkpointed commits), step `migration_state` back **one** version, and open it under both `SPACES_DB_PATH` and `SPACES_RUNTIME_DIR` pointing at scratch. **That spawns a daemon for the scratch profile which outlives the command** — sweep it afterwards. Stepping back further than one version does not replay the chain; use a unit test against a genuinely old fixture for that.

## 10. Clean up

1. Close every session you created; intersect against the live list and preserve everything else.
2. An agent TUI ignores `exit` and `Ctrl-D` — terminate the agent process directly, then exit the shell.
3. Sweep for stray daemons bound to scratch runtime dirs, and for leaked generators by pattern.
4. `diff` project ids, workspace ids, and `git worktree list` against the opening snapshot; show the empty diffs.
5. Re-measure the settled baseline against the starting one. Anything that did not return is either a finding or an explicit non-finding.
