---
name: qa-sweep
description: Stress-test, soak-test, and QA the installed Spaces app and daemon on this machine — CPU, memory, file descriptors, database growth, terminal throughput, latency, pane switching, coding-agent lifecycle, daemon handoff, crash recovery, and migrations — then file issues for the defects that survive verification. Use when asked to stress test, soak test, profile CPU or memory, hunt performance regressions or leaks, or run QA against the real app.
---

# QA sweep of the live Spaces build

Measure the running build. Source explains *why* a number is what it is; it never establishes *that* it is. Every finding in the report must trace to something you measured on this machine.

Every procedure and gotcha below was validated against the installed build. Where something is marked unsafe or unavailable, that was established by trying it.

## Ground rules

1. **Target the installed build**: `/Applications/Spaces.app/Contents/MacOS/SpacesApp`, `~/.spaces/bin/spacesd`, and the app's `caddy`. Match daemons with an anchored pattern (`pgrep -f "^$HOME/.spaces/bin/spacesd"`) so other worktrees' daemons never match. Never kill them.
2. **Establish what you are testing.** Compare the installed binary's build time against the repo: `git log --oneline HEAD..v<version>` and `HEAD..origin/main`. The installed build can be *ahead* of your checkout, not only behind. State the relationship, and confirm each finding's code path still exists at `HEAD`.
3. **Never create projects or workspaces.** `spaces workspace` exposes only list/create/start/restart and `spaces project` only `list` — there is **no stop, remove, delete, or archive**. A workspace you create cannot be removed programmatically and permanently pollutes the user's list. Do workspace/worktree lifecycle QA on a disposable dev profile instead.
4. **Every load generator is deadline-bound and self-terminating** — bound by volume (`head -c N`) or an internal deadline (`end=$((SECONDS+N))`). Never background an unbounded `yes`/`while true`.
5. **Snapshot before, verify after.** Record project ids, workspace ids, `git worktree list`, and the live session list up front. At the end, `diff` each against the snapshot and show empty diffs in the report.
6. **Keep raw artifacts in the scratchpad**, never in the repo, and never read a full `sample` transcript into context — `grep`/`awk` it.

## 1. Baseline

Capture idle CPU, RSS, thread count, fd count, and DB size for app, daemon, and caddy, plus one `sample <pid> 10` of each.

In a `sample`, ignore idle-wait leaves (`kevent64`, `__workq_kernreturn`, `mach_msg2_trap`, `__psynch_cvwait`, `__ulock_wait2`) — blocked threads, not CPU. Whatever remains is the real cost.

Inventory the database before loading it: row counts per table, and `SELECT name, SUM(pgsize)/1024 FROM dbstat GROUP BY name ORDER BY 2 DESC`. A table holding most of the file with few rows is a finding on its own.

**Check for a live device subscriber first** — see §7. It changes the idle baseline by an order of magnitude, and a baseline taken without one is not comparable to a measurement taken with one.

## 2. Scale one dimension at a time

The highest-yield technique in the sweep, and what turns "feels slow" into a filed issue.

Hold everything constant, vary **one** quantity (live sessions, output volume, rows in a table, open panes), take three or more points, and report the **slope**. A clean linear fit is the strongest evidence available and predicts cost at scales you never ran.

Measure per window: CPU-seconds delta (from `ps -o time=`, never `%cpu`), WAL bytes written, RSS, threads, fds. Idle sessions are the sharpest probe — a session running `sleep` does no work, so anything scaling with it is pure overhead.

## 3. Profile under load

At the highest load point, `sample` the daemon and attribute non-idle frames to app symbols. Two signatures worth knowing:

- More CPU in `sqlite3RunParser` / `yy_reduce` / `sqlite3GetToken` than in `sqlite3VdbeExec` means statements are being re-prepared on fresh connections rather than executed — look for a connection opened per call. Accompanying `__getattrlist`/`stat`/`__open_nocancel`/`__fcntl` means per-row path resolution.
- Heavy `_swift_getGenericMetadata` / `swift_retain` / `swift_release` means generic code in a hot loop; attribute it to the app frame directly above.

Read memory with `vmmap --summary <pid>`, not `ps` RSS alone — they disagree substantially. `Physical footprint` is what macOS charges; `(peak)` gives the high-water you would otherwise miss. Regions marked `(empty)` are freed to the allocator but not returned to the OS: allocator high-water, **not** a leak. Break out `IOAccelerator` separately — GPU memory does not appear where you expect. Compare a region against its own pre-test value before calling it retained; per-session GPU memory that returns to baseline is not a leak.

## 4. Latency

Measure how long things take, not only how much they cost.

- **Establish the CLI floor first**: `spaces --version` is ~7 ms. Never attribute command cost to "CLI startup" without it — `terminal list` at ~147 ms is almost entirely daemon work.
- **Interaction latency**: `spaces terminal send bytes <sid> <byte>` then poll `terminal tail` until the character appears. Measured ~44 ms median, minus an ~11 ms `tail` polling floor measured in the same run, so ~33 ms true.
- **Never use `--submit` for latency.** It sends a deliberately *spaced* Enter (`docs/spec.md:423`) and measured 636 ms end to end. It tests submission, not latency.

## 5. Leak checks

For file descriptors, threads, DB rows, and on-disk directories: sample the count at several points with the *same* number of live sessions, and fit a line against sessions **created**. A clean fit across three or more points is proof; a single before/after pair is not.

Distinguish "held open" from "still on disk" — `lsof` the paths and test each with `[ -e ]`. A descriptor whose file is already unlinked is unambiguous.

Let the process settle for several minutes before declaring memory retained; much of what looks retained right after a burst is returned later.

## 6. Soak

Run a realistic mixed workload for 30+ minutes: long-lived sessions producing output, periodic reads, session churn, and repeated bursts of whatever interaction you are testing. Sample every 5–10 s to CSV with `sampler.sh`.

Look for **drift and degradation**, not absolute values: does RSS trend up after warm-up, does DB size grow, and — most telling — **is a repeated operation as cheap in the last burst as the first?** Identical cost across 20+ bursts is a strong negative result worth reporting.

## 7. Multi-device — check this before trusting any idle measurement

A paired phone or second Mac is a **live overview subscriber**, and it is the single most valuable probe in the sweep. With a subscriber attached and **zero terminal sessions open**, the daemon measured **7.9% of a core continuously** against a 0.6% no-subscriber baseline, attributable to per-row SQLite open/parse/close.

- Detect one: `lsof -nP -p <daemon> | grep ESTABLISHED` on port 47847.
- Always state whether a subscriber was attached. A cost that looks dormant without one becomes a steady-state battery drain with one.

Scope limits, both established by trying:

- `spaces device list` lists **outbound** targets only (often just this Mac). Inbound clients live in `~/.spaces/runtime/terminal/device-pairings.json`. **`--device <iphone>` does not work** — the phone is the client, not a target. Do not plan tests around driving a phone from the Mac.
- iOS pairings all report `deviceName` "iPhone" (accepted behaviour); disambiguate by `appVersion` + `lastUsedAt`.
- On-device UI is not scriptable from here. Test the **daemon side** of what the device asks for; treat the phone's UI as manual verification.

## 8. Feature and UX QA

Drive the product through panes with live Ghostty surfaces — a headless daemon session exercises none of the render, attach, or ownership paths.

- **Panes:** open with `spaces terminal show`, then switch rapidly. Measure cold (first surface) and warm (surface exists) separately; they differ, and not always in the expected direction. Watch app RSS and thread count, and decide whether growth plateaus (working-set bound) or continues (leak). Note that `terminal show` on a session with **no** GUI pane creates no attachment, so ownership-invariant assertions are vacuously true without a real pane.
- **Coding agents:** launch `codex`, `claude`, and `opencode` in panes with output-heavy prompts. Use cheap models (`codex -m gpt-5.3-codex-spark`, `claude --model haiku`) and keep them read-only (`--sandbox read-only`, `--permission-mode plan`) so an unattended soak cannot modify the repo.
  `spaces agent spawn --command` does not inherit the login shell's `PATH`, so a version-manager-installed agent is not found. Start agents the way a user does: `terminal command` → `terminal show` → `terminal send text '<launch command>' --submit`.
- **Agent lifecycle**, verified end to end by sending `spaces agent signal <ev>` from inside a Spaces terminal: `init→idle`, `working→spinning`, `blocked→`**`waiting`**, `done→done`, `exit→exited`, with `agent_session_events` incrementing per signal. Assert on the rendered string — `blocked` surfaces as `waiting`. `agent_pending_notifications` is the cross-device watch queue, not the local Alerts feed; do not use it to assert local alert state. Dock badge and Alerts attention are GUI-only — assert the transition and leave the visual to manual checking.
- If every agent reads `idle signaled=false` while visibly working, **the hook chain is broken before you conclude anything about the classifier**. Hook commands end in `>/dev/null 2>&1 || true`, so a wrong `spaces` path fails silently every time. Check `~/.codex/hooks.json`, `~/.claude/settings.json`, and `~/.config/opencode/plugin/spaces-agent-signal.js`.

## 9. Concurrency

- Parallel `terminal command` (12 at once): all succeed, list delta matches exactly. Assert no lost writes.
- Concurrent `terminal show` on one session: owner attachments must stay ≤ 1.
- Hold the DB write lock from a separate connection. Under the 5 s busy timeout, nothing is disturbed. **Past it, reads still succeed (WAL) but a CLI write hangs ~30 s and fails with "Resource temporarily unavailable"** — 30 s is an RPC timeout, not the SQLite busy timeout, and the message names no cause.
- Churn create/exit and check for runtime rows with no session row.

## 10. Resilience: handoff and crash

Test the two paths separately; they have opposite expected outcomes.

**Graceful handoff — sessions must survive.** Create marker sessions (`sh -c 'echo MARK-N; sleep 600'`) so the marker proves the same pty survived rather than a fresh session appearing. Record the daemon pid and each `child_pid`, run `spaces daemon apply-update`, wait ~8 s, then assert: daemon pid **unchanged** (exec-in-place), every `child_pid` unchanged **and alive**, and every pre-handoff marker still in `terminal tail`. Session count alone passes trivially — `child_pid` equality is the load-bearing assertion.
`apply-update` is async (returns in ~62 ms). Confirm a handoff actually happened in `~/.spaces/runtime/spacesd.launchd.err.log`: `handoff_preflight_ok` → `handoff_quiesced` → `handoff_exec` → `handoff_resume`. Otherwise a no-op is indistinguishable from a pass.

**SIGKILL — sessions must die, state must repair.** launchd restarts the daemon in ~2 s with a new pid. Sessions cannot survive (the pty master fds die with the process); that is inherent, not a defect. Assert instead that every profile-owned row moved `running` → **`failed`** with its dead `child_pid` retained, and that the daemon is healthy afterwards. Rows still claiming `running` after recovery indicate rows the repair cannot see.

## 11. Migrations and data integrity

1. `sqlite3 "file:$HOME/.spaces/spaces.db?mode=ro" ".backup '<scratch>/replay.db'"` — WAL-aware; a plain `cp` can miss un-checkpointed commits.
2. `UPDATE migration_state SET current_version=<n-1>` on the **copy**.
3. Open with the real CLI under **both** `SPACES_DB_PATH` and `SPACES_RUNTIME_DIR` pointing at scratch.
4. Assert the version advanced and row counts are unchanged.

**Opening an isolated profile spawns a daemon for it that outlives the command.** Always sweep afterwards:
`for p in $(pgrep -f spacesd); do ps eww -p $p | tr ' ' '\n' | grep -q "SPACES_RUNTIME_DIR=.*<scratch>" && kill $p; done`

Step back only **one** version. Forcing to v1 on a current-shaped DB does not replay the chain — it fails with "Timed out waiting for spacesd to start". Exercise the full chain from a unit test against a genuinely old fixture instead.

## 12. Energy

`powermetrics` needs a sudo password and will block an unattended run — reach for it only when the user is present, and say so rather than skipping silently.

The non-sudo proxy works and is already installed: `psutil.Process(pid).cpu_times()` and `.num_ctx_switches()` (context switches **are** available on macOS). Report the wakeup **rate** next to CPU% — a low-CPU, high-wakeup process still drains battery. Measured at idle: daemon 8.7% of a core with ~539 ctx switches/s; app 0.0% with ~3/s.

## 13. Prove it, or drop it

Most of the value is here. A plausible mechanism is not a finding.

1. **Run the control.** Before attributing a cost to X, build the same workload without X. Process churn was blamed for a 10× CPU cost until fork-heavy and fork-free workloads of equal byte volume both measured 3%.
2. **Warm the cache and repeat the operation.** A microbenchmark that never repeats measures cache-miss cost. Probing unique non-existent filenames against a cold directory overstated a lookup penalty 50×; warm and repeated, it was 1.4×.
3. **Ask whether a clean install would hit this.** A dev machine carries many profiles, stale global config, and test residue. If the mechanism needs any of that, it is an environment artifact — say so and do not file it.
4. **Check the docs before calling something a bug.** `docs/spec.md` may define the behaviour deliberately. If the user disagrees with documented behaviour, raise the conflict rather than silently changing course.
5. **Correct yourself in place.** When a measurement is refuted, amend the issue and tell the user plainly. A retracted finding costs far less than a wrong one someone acts on.

Delegate each surviving finding to a subagent for root-cause analysis against the source, giving it the numbers. Require file:line evidence and treat its conclusions as claims to verify.

## 14. Triage and file

Build the table before filing: probability of occurrence, impact 1–10, effort to write a failing test (with reason), recommendation.

- File issues for defects that occur at real frequency with real impact, and for trivial correctness fixes.
- Prefer a GitHub issue over a fix for low-impact findings needing disproportionate complexity.
- Document as accepted risk anything irrelevant to product UX; rare edge cases and conditions that self-heal in normal use can be ignored.

Each issue must be reproducible from its own text: the measurement table, the mechanism with file:line anchors, ranked fixes with the risk each carries, and the test that would prove the fix. No agent or review-round provenance. Search open **and** closed issues first — a closed issue describing the same class in a different code path is worth referencing.

## 15. Clean up

1. Close every session you created; intersect your list against the live list and preserve everything else.
2. An agent TUI ignores `exit` and `Ctrl-D`. Terminate the agent process directly, then exit the shell.
3. Sweep for stray daemons bound to scratch runtime dirs, and for leaked generators by pattern.
4. `diff` project ids, workspace ids, and `git worktree list` against the opening snapshot and show the empty diffs.
5. Re-measure the settled baseline against the starting baseline. Anything that did not return is either a finding or an explicit non-finding.
