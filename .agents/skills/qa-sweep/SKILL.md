---
name: qa-sweep
description: Stress-test, soak-test, and QA the installed Spaces app and daemon on this machine — CPU, memory, file descriptors, database growth, terminal throughput, pane switching, and coding-agent lifecycle — then file issues for the defects that survive verification. Use when asked to stress test, soak test, profile CPU or memory, hunt performance regressions or leaks, or run QA against the real app.
---

# QA sweep of the live Spaces build

Measure the running build. Source explains *why* a number is what it is; it never establishes *that* it is. Every finding in the report must trace to something you measured on this machine.

## Ground rules

1. **Target the installed build**, not a repo build: `/Applications/Spaces.app/Contents/MacOS/SpacesApp`, `~/.spaces/bin/spacesd`, and the app's `caddy`. Other worktrees' `spacesd` processes belong to other profiles — never kill them.
2. **Establish what you are testing.** Compare the installed binary's build time against the repo: `git log --oneline HEAD..v<version>` and `HEAD..origin/main`. The installed build can be *ahead* of your checkout, not only behind. State the relationship in the report, and confirm each finding's code path still exists at `HEAD`.
3. **Every load generator is deadline-bound and self-terminating.** Bound by volume (`head -c N`) or by an internal deadline (`end=$((SECONDS+N))`). Never background an unbounded `yes`/`while true`. Sweep with `pgrep` when done — see Clean up.
4. **Keep raw artifacts in the scratchpad**, never in the repo, and never read a full `sample` transcript into context — `grep`/`awk` it.
5. **Do not disturb the user's work.** Record which sessions existed before you started; close only what you created.

## 1. Baseline

Capture idle CPU, RSS, thread count, fd count, and DB size for app, daemon, and caddy, plus one `sample <pid> 10` of each. Record the live terminal-session list — that is the preserve-list for cleanup.

In a `sample`, ignore idle-wait leaves (`kevent64`, `__workq_kernreturn`, `mach_msg2_trap`, `__psynch_cvwait`, `__ulock_wait2`) — they are blocked threads, not CPU. Whatever remains is the real cost.

Inventory the database before loading it: row counts per table, and `SELECT name, SUM(pgsize)/1024 FROM dbstat GROUP BY name ORDER BY 2 DESC`. A table holding most of the file with few rows is a finding on its own.

## 2. Scale one dimension at a time

This is the highest-yield technique in the whole sweep, and it is what turns "feels slow" into a filed issue.

Hold everything constant, vary **one** quantity (live sessions, output volume, rows in a table, open panes), and take three or more points. Report the **slope**, not the endpoints. A clean linear fit is the strongest evidence you can produce, and it predicts the cost at scales you never ran.

Measure per window: CPU-seconds delta (from `ps -o time=`, not `%cpu`), WAL bytes written, RSS, threads, fds.

Idle sessions are the sharpest probe — a session running `sleep` does no work, so anything that scales with it is pure overhead.

## 3. Profile under load

At the highest load point, `sample` the daemon and attribute the non-idle frames to app symbols. Two signatures worth knowing:

- More CPU in `sqlite3RunParser` / `yy_reduce` / `sqlite3GetToken` than in `sqlite3VdbeExec` means statements are being re-prepared on fresh connections rather than executed — look for a connection opened per call.
- Heavy `_swift_getGenericMetadata` / `swift_retain` / `swift_release` means generic code in a hot loop; attribute it to the app frame directly above.

Read memory with `vmmap --summary <pid>`, not `ps` RSS alone — they disagree substantially. `Physical footprint` is what macOS charges; `(peak)` gives the high-water you would otherwise miss. Regions marked `(empty)` are freed to the allocator but not returned to the OS: allocator high-water, **not** a leak. Break out `IOAccelerator` separately — GPU memory does not show up where you expect it.

## 4. Leak checks

For each of file descriptors, threads, DB rows, and on-disk directories: sample the count at several points with the same number of live sessions, and fit a line against sessions *created*. A clean fit across three or more points is proof; a single before/after pair is not.

Distinguish "held open" from "still on disk" — `lsof` the paths and test each with `[ -e ]`. A descriptor whose file is already unlinked is unambiguous.

Let the process settle for several minutes before declaring memory retained. Much of what looks retained immediately after a burst is returned later.

## 5. Soak

Run a realistic mixed workload for 30+ minutes: long-lived sessions producing output, periodic reads, session churn, and repeated bursts of whatever interaction you are testing. Sample every 5–10s to a CSV.

Look for **drift and degradation**, not absolute values: does RSS trend up after warm-up, does DB size grow, and — most telling — **is the cost of a repeated operation the same in the last burst as the first?** Identical cost across 20+ bursts is a strong negative result worth reporting.

## 6. Feature and UX QA

Drive the product the way a user does, through panes with live Ghostty surfaces — a headless daemon session exercises none of the render, attach, or ownership paths.

- **Panes:** open panes with `spaces terminal show`, then switch rapidly between them. Measure cold (first surface) against warm (surface exists) separately; they differ, and not always in the direction you expect. Watch app RSS and thread count, and check whether growth plateaus (a working-set bound) or continues (a leak).
- **Coding agents:** launch `codex`, `claude`, and `opencode` in panes and drive them with output-heavy prompts. Use cheap models — `codex -m gpt-5.3-codex-spark`, `claude --model haiku` — and keep them read-only (`--sandbox read-only`, `--permission-mode plan`) so an unattended soak cannot modify the repo.
  `spaces agent spawn --command` does not inherit the login shell's `PATH`, so a version-manager-installed agent is not found. Start the agent the way a user does: `terminal command` → `terminal show` → `terminal send text '<launch command>' --submit`.
- **Agent lifecycle:** verify the full chain — `working`/`spinning` while busy, `done` on completion, `exited` on teardown, and that status is correct after `agent interrupt`. If every agent reads `idle signaled=false` while visibly working, the hook chain is broken before you conclude anything about the classifier: hook commands end in `>/dev/null 2>&1 || true`, so a wrong `spaces` path fails silently every time. Check `grep spaces-agent-hook ~/.codex/hooks.json ~/.claude/settings.json` and `~/.config/opencode/plugin/spaces-agent-signal.js`.

## 7. Prove it, or drop it

Most of the value is here. A plausible mechanism is not a finding.

1. **Run the control.** Before attributing a cost to X, construct the same workload without X. This is what separates a real finding from a story: process churn was blamed for a 10x CPU cost until a fork-heavy and a fork-free workload of equal byte volume both measured 3%.
2. **Warm the cache and repeat the operation.** A microbenchmark that never repeats an operation measures cache-miss cost, not steady-state cost. Probing unique non-existent filenames against a cold directory once overstated a lookup penalty 50x; warm and repeated, the real figure was 1.4x.
3. **Ask whether a clean install would hit this.** A dev machine carries many profiles, stale global config, and test residue. Determine whether the mechanism requires any of that. If it does, it is an environment artifact — say so and do not file it.
4. **Check the docs before calling something a bug.** `docs/spec.md` may define the behavior deliberately. If the user disagrees with documented behavior, raise the conflict rather than silently changing course.
5. **Correct yourself in place.** When a measurement is refuted, amend the issue and tell the user plainly. A retracted finding costs far less than a wrong one someone acts on.

Delegate each surviving finding to a subagent for root-cause analysis against the source, and give it the numbers. Require file:line evidence and treat its conclusions as claims to verify, not facts.

## 8. Triage and file

Build the table before filing anything: probability of occurrence, impact 1–10, effort to write a failing test (with reason), and a recommendation.

- File issues for defects that occur at real frequency with real impact, and for trivial correctness fixes.
- Prefer a GitHub issue over a fix for low-impact findings that need disproportionate complexity.
- Document as accepted risk anything irrelevant to product UX; rare edge cases and conditions that self-heal in normal use can be ignored.

Each issue must be self-contained and reproducible from its own text: the measurement table, the mechanism with file:line anchors, ranked fixes with the risk each carries, and the test that would prove the fix. No agent or review-round provenance. Search open *and* closed issues first — a closed issue describing the same class in a different code path is worth referencing.

## 9. Clean up

1. Close every session you created; intersect your list against the live list and preserve everything else.
2. An agent TUI ignores `exit` and `Ctrl-D`. Terminate the agent process directly, then exit the shell.
3. Sweep for leaked generators by pattern and by process group.
4. Re-measure the settled baseline and report it against the starting baseline. Anything that did not return is either a finding or an explicit non-finding.
