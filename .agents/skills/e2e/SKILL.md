---
name: e2e
description: Run the real-system E2E lanes and the latency/render profiling scenarios, tell a flake from a regression, and report the numbers. Use when asked to run e2e, run a specific lane or scenario, measure or compare terminal/mobile/remote latency, profile render updates, or verify a change on the real system rather than in unit tests.
---

# E2E lanes and latency measurement

These lanes are the **correctness gate on the real system**: a real daemon, real terminal sessions, a real app with real windows, real simulators, and a real paired Linux device. They assert known invariants and produce pass/fail. Everything they cover is deliberately *not* re-tested by hand.

The complementary skill is **`qa`**, which hunts what these lanes structurally cannot see — accumulation, leaks, degradation over time, and the installed build under launchd. The boundary is sharp:

- Deterministic pass/fail on a clean profile → belongs here, as a lane.
- A cost that grows, a tail that collapses under sustained load, a real long-lived profile → belongs in `qa`.

`docs/dev.md` is the authority on invocation, flags, artifact paths, and what each lane asserts. Read the relevant part of it rather than trusting a remembered command line; this skill carries the judgement around those commands, not a copy of them.

## 1. Pick the smallest lane that covers the change

```
apps/macos/Tests/e2e.sh <app|terminal|mobile|device-api|all|exhaustive|mobile-demo> [--scenario <name>] [--list]
```

`--list` prints a lane's scenarios and is the fastest way to avoid guessing a name. Batch several `--scenario` flags rather than running the lane repeatedly — sibling latency and mobile-UI scenarios batch into a single script invocation.

- **`app`** — window cycling, focus, sidebar targets. `smoke`/`window-cycle` for the compact profile, `full` for everything. Desktop-control heavy: see §2.
- **`terminal`** — daemon and CLI behaviour with no app: `cli`, `daemon-idle-shutdown`, `daemon-exec-handoff`, `edit-shortcuts`, `mouse-reporting-scroll`, `ended-session-scroll`, `agent-orchestration`, plus the profiling scenarios (`built-in-terminal-profile`, `workspace-terminal-open`, `spaces-terminal-hotkeys`, `spaces-terminal-palette`, `stress`, `soak`, `device-api-profile`) and the `mac-*-latency` set.
- **`mobile`** — simulator UI scenarios (`takeover`, `codex`, `roundtrip`, `scrollback`, `two-session`, `ownership-guard`, …) and the `ios-*-latency` set.
- **`device-api`** — `local`, `remote`, `latency-compare`, `profile`. Everything but `local` needs the remote host.
- **`all`** is the shared-setup smoke lane; **`exhaustive`** is the full manual sweep and takes a long time. Reach for `exhaustive` when gating a release or a change that touches the terminal stack broadly, not to check one fix.

Every invocation writes a Markdown report under `apps/macos/.artifacts/e2e-runs/<timestamp>-<lane>/summary.md`, with the command timeline, per-case timings, per-step logs, and flattened metric tables. **Read the report rather than scrolling the console** — and cite it when reporting results.

`agent-orchestration`'s always-runnable part drives the lifecycle with explicit `spaces agent signal` events and no real agents. Exercising the *real* claude/codex/opencode CLIs through their real hook configuration is the `qa` skill's job, not this lane's — `SPACES_E2E_AGENT_MATRIX=1` is the lane's own opt-in and is not a substitute for that pass.

## 2. Prerequisites that silently ruin a run

1. **Run this worktree's own binaries.** `e2e.sh` builds and execs `apps/macos/.build/debug/spacese2e`, which resolves its own worktree-scoped profile from where it sits. Never export `SPACES_DB_PATH` to reach a real profile — an inherited binding is exactly what lets one profile's daemon serve another's state.
2. **Leave other worktrees alone.** Other running Spaces instances are separate profiles. Do not kill them to unblock a run; stop only the current profile's app instance, and let desktop-global lanes wait for desktop control when another profile owns it.
3. **Run in the foreground.** A backgrounded e2e run gets killed on dormancy and reports long after the fact. Own these runs from the main loop.
4. **Quiet machine.** These lanes are timing-sensitive; a concurrent build or stress run in another worktree produces failures that are about load, not the code. The mirror-surface suites are stricter still — only one embedded ghostty app may be live per process and effectively one consumer machine-wide, so `SurfaceSnapshotTimeout` usually means a second run is already going. Check `pgrep -af 'SpacesApp|spacesd|spacese2e|xctest'` before blaming the change.
5. **The `app` lane takes over the desktop, and drives the user's real Chrome.** It closes real browser windows. Do not run it repeatedly on a machine someone is using; say what it will do and let the user choose the moment.
6. **Two environment states make a desktop lane fail misleadingly — rule them out before blaming the lane.**
   - **A locked screen.** With the screen locked, AX still reports an app's windows, titles, and focused/main, but publishes no `kAXPosition`/`kAXSize` — so any lane that resolves a window frame to post a mouse event fails with a message about the window, not about the lock. Check it directly (`CGSessionCopyCurrentDictionary()`'s `CGSSessionScreenIsLocked`) rather than inferring it, and abort the run instead of recording the results: a whole run of desktop lanes will fail for this one reason. The control that identifies it in one step is re-running a desktop lane that passed earlier in the same session — if a lane whose code did not change now fails, suspect the environment, not the diff.
   - **Another instance owning desktop-global control** (`spacese2e profile-desktop-control-owner`). A lane that leaks a `SpacesApp` leaves it holding the lease, and every later desktop lane then fails after its full wait with an unrelated-looking message. Only ever stop an instance your own run created.
7. **Remote lanes need `.env`.** `scripts/spaces-e2e-env.sh` sources the gitignored repo-root `.env`; a fresh worktree has none, so copy it in. A remote daemon must be on the same wire-protocol version as the local build — redeploy with `apps/macos/scripts/deploy_linux_spacesd_e2e.sh` first. Tailscale SSH returns exit 0 for everything, so never trust a remote exit code alone; check the output.
8. **Ghostty artifacts must match the pinned submodule.** `ghostty_session_new_headless failed` / `ghostty_mirror_new failed` is usually artifact skew or a stale debug daemon, not a product bug — `apps/macos/scripts/setup_ghostty.sh --build` rebuilds from the pin. After switching branches in a worktree, clean the stale debug products first.
9. **Never pipe the run** through `tee`/`head` in a way that masks the exit code.

## 3. Latency and profiling scenarios

These are fast performance-iteration lanes, not the canonical correctness gate. They fail only on gross regressions; the value is in the numbers they write, so **always report the numbers, never just "it passed."**

- Mac terminal: `mac-input-latency`, `mac-scrollback-latency`, `mac-scrollback-partial-latency`, `mac-command-output-catchup`.
- iOS: `ios-input-latency`, `ios-scrollback-latency`, each under `--network-profile local` or `ios-constrained`.
- Remote: `device-api latency-compare`, which measures a Device API remote workspace against a local terminal SSH'd into the same remote directory — the honest comparison, because both do the same work over different transports.
- Render bytes: run a latency scenario with `--samples N --keep-root`, then summarize the preserved JSONL with `apps/macos/Tests/render_update_profile_summary.py`.

Reporting rules:

1. **p50, p95, max — never a mean.** Head-of-line blocking leaves the median clean while the tail collapses. The summaries already split the phases (enqueue→RPC, RPC duration, frame apply, RPC-end→visible); report the split when one phase is the whole story.
2. **Warm up and repeat.** A single cold pass measures cache-miss cost. Raise `--samples` before drawing a conclusion; a cold-directory measurement once overstated a penalty by more than an order of magnitude.
3. **Before and after, same machine, same conditions.** A perf claim needs both numbers in one table, and the table goes on the PR.
4. **Say which network profile and which target produced each number.** `local` and `ios-constrained` are not comparable, and neither are Mac and iOS totals — they measure different endpoints.
5. **Confirm each enforced metric actually has samples.** A budget compared against a `None` p95 is skipped, so the lane passes unconditionally and gates nothing. Report the sample count beside every percentile.
6. **Confirm the lane exercises the path a user takes.** A scenario that drives a programmatic submit measures that path's deliberate input pacing, not terminal latency — user typing is a text write plus a separate Return keystroke and does not go through the submit sequencer. Getting this wrong makes a lane report an order of magnitude too slow and hides the render cost it exists to track.

Attribute a slow phase before calling it a hotspot: take the per-phase p50/p95 breakdown, then confirm with an independent measurement outside Spaces (a raw PTY driving the same shell) and with the daemon's own perf log. A wide phase often means the process being waited on had not produced output yet, rather than that the phase is expensive.

## 4. Flake, harness drift, or regression

When running the whole matrix, drive **one invocation per lane/scenario**, recording pass/fail per case and continuing past failures. The `exhaustive` lane aborts on its first failure, so a single early break hides the rest; driving each scenario separately yields the complete inventory in one pass. Cover every `app`, `terminal`, `mobile`, and `device-api` scenario plus `device-api latency-compare`, which `exhaustive` omits.

Classify every failure before investigating anything, because the kinds need opposite responses:

- **Harness drift** — the test encodes a contract the product no longer has. Fix the test and open a PR. Signatures: a wire/format version the product has moved past; a CLI verb that no longer exists (exit 64, "unexpected arguments"); a wait on a perf metric or detail field nothing emits; a missing argument the command now requires.
- **Product defect** — file an issue with a priority label.
- **Flake** — decided by the steps below, never assumed.

Read the failure, do not trust its message. Failures mislead in three recurring ways: a decoder that returns `None` on error and a caller that formats `None` as a plausible value (a stale format gate reported a themed background as `#000000`); one broken shared bootstrap step failing every lane for one reason; and a leaked process poisoning later lanes.

Assume neither flake nor regression. Decide it:

1. Re-run the failing scenario alone on a quiet machine. Most timing failures do not survive isolation.
2. If it fails in CI only, check whether other PRs' runs fail the same way at the same step — a shared failure is infrastructure, not the change. Worker oversubscription on a small runner shows up as a live-but-silent child; cap the workers rather than raising timeouts.
3. Re-run at the merge-base. A failure that reproduces without the change is not the change's.
4. Only after those three: read the step log in the run report and treat it as a real defect.

Record which of these you did. "Reran and it passed" without saying why is not a diagnosis.

## 5. When a lane finds something real

Fix the product, not the lane. Loosening an assertion or widening a budget to make a run green needs an explicit reason and the user's agreement — the budget is the gate.

If a defect has no lane, add one: the scenario tables in `apps/macos/Sources/spacese2e/E2ERunner.swift` are the single source of truth for lane/scenario/dispatch, so a new scenario is registered there and dispatched to its script. A defect that reaches here from the `qa` sweep should arrive with the assertion already described; turning it into a lane is what stops it recurring.

## 6. Clean up and report

Preserved run roots (`--keep-root`) and `.artifacts/` accumulate; keep the ones you cite and say where they are. Sweep for daemons left bound to scratch runtime dirs, matching your own profile only.

Close with: the lanes and scenarios run, pass/fail per scenario, the report path, a measurements table for anything timed (metric, before, after, delta, condition), and an explicit note on any failure you classified as a flake with the evidence for that call.
