# Spaces Development

Build, test, and release workflows for the Spaces monorepo. For product overview and adoption, see [README.md](../README.md).

## Repo Layout
- `apps/macos`: macOS app, `spaces` CLI, Swift sources, tests, product docs
- `apps/web`: static marketing site and user-facing docs
- `scripts`: root wrappers for build, test, coverage, release, and deploy workflows

## Documentation Map
- [`README.md`](../README.md): product overview and adoption pitch
- [`AGENTS.md`](../AGENTS.md): how coding agents should write, verify, and document changes
- [`docs/spec.md`](spec.md): expected product behavior and UX
- [`docs/implementation.md`](implementation.md): module boundaries, data model, and implementation rationale
- [`docs/terminal.md`](terminal.md): built-in terminal and libghostty integration notes, constraints, and verification guidance
- [`docs/design.md`](design.md): visual system and interaction patterns
- [`apps/web/app/docs`](../apps/web/app/docs): user-facing product and CLI documentation

## Requirements
- macOS 14+
- Google Chrome

## macOS App and CLI

Run from the repository root:

```bash
scripts/format.sh
scripts/swiftpm.sh build
scripts/swiftpm.sh test --parallel
scripts/lint.sh
scripts/coverage.sh
scripts/verify.sh
```

`scripts/format.sh` performs an explicit tree-wide `swift format` pass across the macOS and iOS source and test trees using the repository-root `.swift-format`, forwarding any arguments to the underlying `swift format format` invocation.
`scripts/format-staged-swift.sh` formats staged macOS and iOS Swift source and test files with the same configuration and re-stages them.
`scripts/lint.sh` runs `scripts/format-staged-swift.sh` and then `SwiftLint` when `swiftlint` is available.
`scripts/coverage.sh` builds coverage-enabled SwiftPM test targets into their own persistent scratch path, `apps/macos/.build/coverage-scratch`, then runs the already-built tests in parallel. `--enable-code-coverage` instruments every target it builds, executables included, and an instrumented executable run without `LLVM_PROFILE_FILE` drops a `default.profraw` into its working directory — so coverage keeps its build out of the shared `.build` that holds `spaces`, `spacesd`, `spacese2e`, and `SpacesApp`. The separate tree also keeps the plain and instrumented builds from invalidating each other, since toggling the coverage flag inside one scratch tree recompiles the whole package; both stay incremental across runs at the cost of a second build directory on disk. Process-wide environment mutations stay isolated because XCTest cases run in separate processes and the few Swift Testing suites that override `SPACES_DB_PATH` are serialized. Set `SPACES_TEST_PARALLEL=0` to force a serial run when debugging a contention issue; auto-detected workers default to the machine's logical CPU count, overridable with `SPACES_TEST_WORKERS` or cappable with `SPACES_TEST_MAX_AUTO_WORKERS`. The tests that assert real child-process lifecycle and signal delivery run in a dedicated serial process because parallel macOS workers can starve their spawned shell groups and report false termination failures; their raw profiles use the shared coverage scratch and merge into the generated artifacts. The mirror-surface suites are excluded from the shared parallel run and executed together in their own follow-up process against the same coverage scratch: `GhosttyMirrorGraphemeClusterTests`, `GhosttyMirrorLinkActivationTests`, `GhosttyMirrorSurfaceMRUTests`, and `GhosttyMirrorSurfacePresentationTests` start a real mirror-owned ghostty app, and only one embedded ghostty app may be live per process, so a parallel worker that already ran a daemon-core suite cannot host them — the follow-up invocation guarantees a process the mirror service owns. That follow-up step is skipped on CI runners (`GITHUB_ACTIONS`), which cannot host a rendering ghostty surface at all — the suites time out there even in their own process, on artifacts byte-identical to ones that pass locally — so local verify is their gate, like the desktop e2e lanes. Coverage also points `XDG_CONFIG_HOME` at an empty build-local directory so Ghostty tests do not load a developer's personal Ghostty config.
`scripts/verify.sh` is the canonical local verification path: simulator lifecycle regression tests, a Ghostty artifact sync (`setup_ghostty.sh`) that installs the artifacts matching the pinned submodule before anything compiles, staged formatting and lint, one plain SwiftPM build, release bundle signing, repo-local profile export, current-profile app and spacesd shutdown, then the SwiftPM coverage test run and the iOS unit test lane together. The artifact sync keeps the local gate from silently building against a stale `apps/macos/.local` GhosttyKit that drifted from the pin (mirroring the `ensure_ghostty_artifacts.sh` step CI runs before verification); it is a no-op when the installed manifest already matches. That build produces the uninstrumented `.build/debug` binaries the run then signs and executes; `coverage.sh` builds the instrumented test tree in its own scratch path, so neither build instruments the product binaries and neither invalidates the other's incremental state. The profile shutdown is scoped to the repo-local profile so native Ghostty tests do not contend with a running debug app; set `SPACES_VERIFY_KEEP_PROFILE_RUNTIME=1` to leave that runtime running. The iOS unit pass prefers an available shut-down iPhone simulator so it does not attach to a simulator already owned by mobile E2E, explicitly boots it and waits until it is ready, and includes the host simulator architecture in the generated destination so Xcode resolves one concrete simulator target. Simulator selection and the DerivedData path are fixed parts of this canonical workflow, with DerivedData under `apps/macos/.build/ios-derived-data`, reused incrementally across runs rather than cleaned; use a direct `xcodebuild` invocation for one-off destination or build-directory experiments. `coverage.sh` runs in the foreground while the iOS lane runs in the background against its own DerivedData and simulator, since neither shares state with the SwiftPM build/test path; the iOS lane's output goes to `apps/macos/.build/ios-verify.log`, which verify.sh tails after that lane finishes, and verify.sh fails if either lane fails. Verification and the mobile demo/E2E harness shut down only the simulators they boot, including after failure or interruption; simulators that were already booted remain running. SwiftPM coverage tests and iOS tests are built before execution, and only the already-built test processes run under the silence watchdog. Compilation, linking, coverage export, and other build steps have no elapsed-time or silence ceiling. A test process that produces no output for `SPACES_VERIFY_STALL_SECONDS` (default 600) is force-killed with its descendants and fails the gate; set the value to `0` to disable the test watchdog when attaching a debugger.
Every `scripts/verify.sh` run closes with a lane summary. It prints from the script's exit trap, so it appears on a pass, on a lane failure, on an interrupt, and on the early `verify-prep.sh` failures — lint, the SwiftPM build, release bundle signing — that end a run before either test lane exists. Each lane reports whether it never started, started without finishing, passed, or failed, so the summary never claims coverage the run did not have. It also names what no verify.sh lane covers: the desktop, mobile, and remote-daemon E2E suites, and the Linux daemon unit lane and Linux artifact smoke test, which run in CI.
`scripts/swiftpm.sh` binds every `test` invocation to a throwaway profile under `apps/macos/.build/test-profile`, which is why tests never read or write the installed profile or the developer's worktree profile. Profile resolution refuses the installed profile outright in a test process, so a test run outside this wrapper fails loudly instead of writing fixture sessions into the user's database. Suites that scope the profile per test restore this run-level value rather than clearing it, which keeps a suite that restores mid-run from stranding a concurrent suite — Swift Testing runs distinct suites in parallel in one process. `scripts/swiftpm.sh` also uses a fail-fast lock around SwiftPM itself so overlapping build, test, or coverage commands stop immediately with a clear message instead of silently contending on the shared `.build` directory.
`scripts/impacted_tests.sh` speeds up the inner dev loop by running only the SwiftPM test targets affected by the working tree's changes against `origin/main`: it maps each changed path to its SwiftPM target, walks the target dependency graph (from `swift package describe`) to the test targets that transitively depend on it, and runs `scripts/swiftpm.sh test --filter` scoped to that set. A change outside `Sources/`/`Tests/` under `apps/macos` (`Package.swift`, `Package.resolved`, `scripts/`, ...) runs the full suite instead, since those can change the build graph or test tooling itself. All test targets still link into one merged test bundle, so the build step is always full; this script only narrows which already-built tests execute, and it does not replace `scripts/verify.sh` as the pre-commit gate.

Useful local entry points:

```bash
apps/macos/.build/debug/SpacesApp
apps/macos/.build/debug/spaces --help
apps/macos/.build/debug/spacese2e --help
apps/macos/.build/debug/spaces project list
apps/macos/.build/debug/spaces workspace create --project <project-id> --branch debug
apps/macos/.build/debug/spaces workspace restart --workspace <workspace-id>
```

Use `scripts/dev-build-and-launch.sh` to launch the debug app without touching the installed app's database. The script prepares Ghostty artifacts before invoking SwiftPM, so branch worktrees restore prebuilt artifacts from the shared cache. Repo-local debug binaries derive a per-worktree profile automatically under `~/.spaces-dev/profiles/spaces/<branch-slug>-<worktree-hash>/`, and the script stops only that profile's running app instance before it relaunches; the profile's spacesd is stopped only when it owns no sessions, so live terminal sessions and workspace processes survive the relaunch and the app reattaches to them. When sessions are preserved, the running daemon may be an older build; the relaunched app applies the staged debug binary through the exec-in-place handoff on its own, and the sessions keep running. A directly run newer `spacese2e` helper refuses to migrate that older daemon's profile; run `apps/macos/.build/debug/spaces daemon apply-update` to perform the same in-place handoff before retrying the helper. When the repo `.env` configures `SPACES_E2E_REMOTE_SSH_HOST`, the script builds or reuses the current-checkout Ubuntu artifact, uploads it, and installs it as a remote *development profile* named after this worktree's local profile: `install.sh --profile <local-profile-name>`, which lays everything that profile owns under `~/.spaces-dev/profiles/spaces/<local-profile-name>/` and runs it as the `spacesd@<local-profile-name>.service` instance. One worktree therefore owns exactly one remote daemon, the remote account's installed `~/.spaces` daemon is left alone, and several worktrees (or several developers) can deploy to the same device at once. No database, runtime, host, or port environment is passed to the installer — a profile-rooted binary resolves all of that from its own path. Readiness is the profile's own two facts: systemd holds its unit instance active and the profile's own CLI answers; the script then prints the profile root and the Device API port the daemon assigned itself, read from that profile's `runtime/terminal/device-api.json`. Remote pairing from the repo-local app or CLI derives the same profile and runs that profile's own `daemon/current/bin/spaces device pair --json` over SSH with no environment prefix; when that CLI is not on the device, pairing reports the profile as not deployed and points back at this script, since the production installer only ever installs `~/.spaces`. Pass `--local` to skip the remote deploy and only build and relaunch locally.

A device whose single `spacesd.service` was pinned to a development profile by an earlier deploy needs that unit stopped once, because the pinned daemon already owns the profile root the new `spacesd@<name>.service` instance is given: the instance loses that profile's daemon instance lock, exits, and the deploy's readiness check fails with a unit status dump. Run `systemctl --user stop spacesd` on the device and deploy again. A development-profile install deliberately never writes `spacesd.service`, so the pinned unit keeps its assignments and a reboot starts it again: clear them for good by running the installer with no arguments on the device, which rewrites that unit to serve the installed profile with no database or runtime assignment of its own. This is a one-time step per device; nothing in the tooling reads the old layout.

A remote development profile is reachable only if its assigned Device API port is open on the device's network. Only the canonical `47847` is conventionally open, so a firewalled device (a cloud VM, a corporate network) needs ingress for the whole development range `47848`–`47947` — one rule covers every profile, since each assigns itself a port inside it. Pairing itself rides SSH and succeeds without that rule; what fails afterward is the pinned-TLS Device API connect, reported as the remote Device API being unreachable at the port the pairing metadata named. On a Google Cloud instance the rule is `gcloud compute firewall-rules create <name> --network <network> --direction INGRESS --action allow --rules tcp:47848-47947 --target-tags <instance-tag>`, matching the source range the device's existing `47847` rule uses.

For manual worktree-local shell sessions, run this checkout's own binaries. Each resolves the worktree profile from where it sits, so no shell binding is involved and none is needed:

```bash
apps/macos/.build/debug/SpacesApp
apps/macos/.build/debug/spaces terminal list
apps/macos/.build/debug/spacese2e profile-show
```

`spacese2e profile-show` reports the resolved profile's root, database, and runtime paths for a script or a manual `sqlite3` session. It is a lookup, not a binding: a shell that exported another worktree's paths would point this checkout's binaries at a profile that is not theirs, which is why nothing exports them.

`SPACES_DB_PATH` names an ephemeral throwaway profile root and nothing else — a scratch run, an E2E harness. Resolution refuses it when it points inside `~/.spaces/` or `~/.spaces-dev/profiles/`, because a real profile is identified by where the running binary lives: the installed profile falls through to `~/.spaces`, a repo-built binary derives its worktree profile from the checkout above it, and a deployed binary derives it from the profile root it sits in. Override `SPACES_RUNTIME_DIR` alongside it only when the runtime files themselves also need to move with that throwaway profile.

`spacese2e profile` is the inventory and cleanup surface for those profiles, which accumulate as worktrees come and go — and, on a shared Linux device, from several developers at once. It lives in `spacese2e` rather than the `spaces` CLI because managing development profiles is not product behavior.

```bash
apps/macos/.build/debug/spacese2e profile list            # this Mac: profile, recorded Device API port, last touched
apps/macos/.build/debug/spacese2e profile list --remote   # the device, plus daemon state and live session count
apps/macos/.build/debug/spacese2e profile stop --remote <name>
apps/macos/.build/debug/spacese2e profile remove --remote <name>
```

`--remote` resolves the device from the same `.env` remote keys every other remote workflow uses, so load that env first. `list --remote` reports each profile's unit state and asks only an already-active profile's own CLI for its session count, since `spaces terminal list` would otherwise resurrect every stopped daemon just to list it. `stop` stops one unit instance and leaves the profile and its unit enabled; `remove` refuses a profile whose daemon still holds sessions (or is running but not answering its CLI — use `stop` first), then disables the instance, verifies systemd reports it stopped, and deletes the profile root. Neither command reads an unanswerable user systemd as a stopped unit: an SSH session that reaches no user service manager on the device is reported as such, and `remove` deletes nothing. Both refuse `(installed)`: the installed profile is the one profile on a device that is nobody's leftover. `profile list` on a Mac has no daemon or session columns because a Mac has no per-profile unit to ask.

That binding is for running the app, CLI, and E2E helpers — not tests. A test process cannot resolve a live profile at all: under XCTest, profile resolution refuses any database under `~/.spaces/` or `~/.spaces-dev/profiles/`, however the branch that produced it arrived there, so a shell that runs bare `swift test` fails loudly instead of writing fixture sessions into the profile its debug app is serving. Run tests through `scripts/swiftpm.sh test` (directly or via `scripts/coverage.sh` / `scripts/impacted_tests.sh`), which rebinds the run to a throwaway profile regardless of what the shell exported.

### Keeping the Chrome Automation grant across rebuilds

Ad-hoc signed SwiftPM debug builds get a fresh cdhash on every rebuild, and the cdhash is the app's TCC identity. So the macOS Automation grant that lets Spaces control Chrome — and any other TCC permission — is lost each rebuild, and the first-run setup screen reappears. Set `SPACES_DEV_CODESIGN_IDENTITY` in the gitignored repo-root `.env` to a stable signing identity (an "Apple Development: …" line from `security find-identity -v -p codesigning`); `dev-build-and-launch.sh` re-signs the built app with it after SwiftPM, keeping the TCC identity constant so the grant survives rebuilds. For a build whose stale record is already blocking the consent prompt, clear it once with `tccutil reset AppleEvents dev.usespaces.spaces`, then click Recheck (or relaunch).

For branch-local Ghostty artifact setup, run:

```bash
apps/macos/scripts/setup_ghostty.sh
```

That installs `GhosttyKit.xcframework`, Ghostty resources, `libghostty-vt` headers, and `libghostty-vt` libraries under:
- `apps/macos/.local/ghosttykit/GhosttyKit.xcframework`
- `apps/macos/.local/ghosttykit/Resources`
- `apps/macos/.local/ghosttyvt/include`
- `apps/macos/.local/ghosttyvt/lib`

`GhosttyKit.xcframework` includes a universal macOS slice, an `arm64` iOS device slice, and an `arm64` + `x86_64` iOS simulator slice so simulator verification works on Apple Silicon and Intel hosts.

Artifact validation requires the platform dynamic `libghostty-vt` runtime library (`libghostty-vt.dylib` on macOS, `libghostty-vt.so` on Linux). A static `libghostty-vt.a` alone is not a complete install because terminal transcript rendering loads the dynamic library at runtime.

The service router also needs a bundled Caddy binary. For branch-local setup, run:

```bash
apps/macos/scripts/setup_caddy.sh
```

That fetches a pinned universal Caddy binary into `apps/macos/.local/caddy/caddy`, mirroring `setup_ghostty.sh`. Standard app packaging invokes the same setup script before bundling Caddy into the app at `Contents/Resources/caddy`; DMG installs link `/usr/local/bin/spaces-caddy` to that bundled resource so launchd-started `spacesd` can run the local reverse proxy for workspace services without replacing a user-managed `caddy` executable.

The Ghostty fork is tracked as the submodule at `apps/macos/vendor/ghostty`. The parent repo's submodule pointer is the single source of truth for the Ghostty commit used by both `GhosttyKit.xcframework` and `libghostty-vt`.
By default, `setup_ghostty.sh` reuses local artifacts only when `apps/macos/.local/ghostty-artifacts/manifest.json` matches the submodule SHA, setup script version, Zig version, Xcode build version, build-optimize mode, and host architecture, and records a clean source build. The host architecture is part of that key because `libghostty-vt` is a host-native dynamic library, so artifacts built elsewhere would unpack and install but fail to load. When the worktree-local artifacts do not match, default setup next checks a shared, content-addressed cache and restores from it with a local copy before falling back to a download. Otherwise it downloads the Spaces-owned GitHub release named `ghostty-artifacts-<full-ghostty-sha>` and validates the same manifest fields before install. When the downloaded release artifact validates except for a different Xcode build, build-optimize mode, or host architecture, default setup leaves the download uninstalled and builds locally from the pinned submodule. The `--download-only` mode used by CI and publishing workflows is download-only and fails on any of those mismatches.

Those fields are build inputs, so they cannot tell a correct artifact set from one whose content is wrong — compiled code that disagrees with the headers shipped beside it keys and validates exactly like a good build, and `verify_ghosttykit.sh` sees the declarations and symbols it expects. The manifest therefore also records `artifact_content_digest`, one SHA-256 over the installed `GhosttyKit.xcframework`, `Resources`, `ghosttyvt/include`, and `ghosttyvt/lib` trees: every file contributes its path and bytes, every symlink its path and target, ordered by raw path bytes so the digest is reproducible on any host. It is computed after the static-library normalization that renames the macOS archive and rewrites the xcframework `Info.plist`, and it is deliberately not part of the artifact key — a key has to be derivable before the content it names exists. Local reuse, a cache restore, and a completed download each recompute it and compare, and a mismatch falls through the same chain a key mismatch does. A downloaded release whose artifacts disagree with its own manifest fails setup instead of installing, because only a republish can repair it. Manifests written under an older schema (`schema_version`) carry no usable guarantee about the artifacts beside them and are invalid on every path, with no grandfathering.

Because the artifact release is keyed on the Ghostty SHA alone and the manifest records no Ghostty build flags, changing the flags `setup_ghostty.sh` passes to `zig build` requires bumping `BUILD_SCRIPT_VERSION` in that script. Without the bump, artifacts built under the old flags keep validating for that SHA. The shell fixtures in `apps/macos/Tests/` read that constant out of the script, so they follow the bump without edits.

Manifest key drift — a bumped `BUILD_SCRIPT_VERSION`, `MANIFEST_SCHEMA_VERSION`, or Zig version, or a moved Xcode pin — makes `ensure_ghostty_artifacts.sh` classify the published release as invalid, so the next trusted publish run rebuilds it and reuploads the full asset set under the current key rather than leaving the release stranded at the old one. `apps/macos/Tests/ensure_ghostty_artifacts_key_drift.sh` covers both directions of that decision against a stubbed release: a drifted key rebuilds and republishes, a matching key downloads and skips the build.

Every macOS workflow selects its toolchain through the `.github/actions/select-xcode` composite action, which pins one Xcode version for CI and is the only place that version is authored. The pin exists because the artifact key includes the exact Xcode build version: on `latest-stable` the runner image moves to a new Xcode as soon as GitHub ships it, republishes the artifacts under that build id, and locks every developer machine that has not upgraded out of artifact reuse. Run the same Xcode the pin names to download prebuilt artifacts instead of rebuilding Ghostty locally. To move the toolchain, bump `xcode-version` in that action, confirm the `macos-15` runner image ships it, and install the matching Xcode locally; the next trusted publish run republishes the Ghostty artifacts under the new build id.

Local Ghostty source builds require Xcode's Metal Toolchain component because Ghostty compiles Metal shaders into the framework artifacts. Install the component with `xcodebuild -downloadComponent MetalToolchain`. If Xcode reports that first-launch packages need authorization, run `sudo xcodebuild -runFirstLaunch` first, then retry the Metal Toolchain install.

The shared cache lives in the primary checkout at `apps/macos/.local/ghostty-cache`, keyed by `<ghostty-sha>/schema=<manifest-schema>-script=<build-script-version>-zig=<zig>-xcode=<xcode-build>-opt=<build-optimize>-arch=<arch>`. The entry path carries the whole set of inputs a manifest is validated against — `setup_ghostty.sh` derives the key and the validity check from one definition — so checkouts that disagree on any of them (a branch that bumps `BUILD_SCRIPT_VERSION` while other worktrees stay behind, say) occupy separate entries and coexist instead of judging each other's artifacts stale and evicting them. Entries under a key nothing resolves to any more are inert: they are ignored, not read, and stay until the cache is removed with the `rm` below. `setup_ghostty.sh` derives that location itself from the checkout's Git common directory, so every worktree on a machine reads and writes one store regardless of which entry point ran setup; a tree that is not a Git checkout fails with an error instead of falling back to a private per-tree cache, which would look like a working cache while each worktree stored its own multi-gigabyte copy. `SPACES_GHOSTTY_CACHE_DIR` relocates the cache for the hermetic setup tests, which run against fixture checkouts. Each entry mirrors the installed `ghosttykit`, `ghosttyvt/include`, `ghosttyvt/lib`, and `ghostty-artifacts` trees (the Zig toolchain is not cached) and is validated against the same manifest fields, and against the manifest's content digest, before a restore. Every successful clean setup seeds the cache, so a worktree on a SHA the primary checkout already built restores by local copy instead of redownloading or rebuilding. The seeding step rechecks the entry it would overwrite, digest included, and replaces one whose stored artifacts no longer match what its manifest records: an entry every restore rejects has to be repaired by the run that rejected it, or it stays to cost the next reader the same wasted restore. Artifacts still install into the running tree's own `apps/macos/.local`; only the cache is shared. Dirty builds (`--build --allow-dirty`) stay local to their worktree and are never written to the shared cache.
The setup flow finishes by running `apps/macos/scripts/verify_ghosttykit.sh`, which checks that the artifact declares and exports the embedded terminal APIs that Spaces uses for raw I/O, host rebinding, session state callbacks, renderer attachment, headless session creation, render-frame export, and mirror renderer surfaces. Passive-viewer attachment exports are not part of the required contract. The same script also fails when any xcframework slice links Ghostty's Sentry crash reporter, which Spaces builds with `-Dsentry=false`; it inspects every slice rather than macOS alone because the iOS slices carry their own copy. That check belongs in artifact verification rather than at the build flag alone: it runs on the local-reuse, cache-restore, source-build, and download paths, and neither the manifest nor the cache key records Ghostty build flags, so an artifact built with Sentry enabled is otherwise indistinguishable from a correct one.

When a Spaces branch depends on Ghostty fork work, edit and commit the fork change inside the submodule, push it to the fork's `spaces` branch, and update the parent repo's submodule pointer:

```bash
git -C apps/macos/vendor/ghostty status --short --branch
git -C apps/macos/vendor/ghostty push origin HEAD:spaces
git add apps/macos/vendor/ghostty
```

PR checks run `apps/macos/scripts/ensure_ghostty_artifacts.sh`, so existing `ghostty-artifacts-<sha>` releases are downloaded and validated before Swift verification starts. Same-repo PRs, manual PR-check runs, and pushes to `main` first run a non-cancelable trusted artifact publisher that builds from the pinned submodule and publishes a reusable release when the release is missing or incomplete for that build environment; verification waits for that publisher and then downloads the artifact. Fork PRs build missing artifacts locally without publishing, and the main-push publisher creates the reusable release after merge. Trusted publish runs repair incomplete artifact releases by rebuilding and uploading the full asset set. After the release is present, refresh local artifacts and run the normal verification pass from the primary checkout, which owns the shared cache that the `rm` clears so setup exercises the download rather than a cache restore:

```bash
git -C apps/macos/vendor/ghostty rev-parse HEAD
rm -rf apps/macos/.local/ghosttykit apps/macos/.local/ghosttyvt apps/macos/.local/ghostty-cache
apps/macos/scripts/setup_ghostty.sh
scripts/verify.sh
```

Spaces app releases run `apps/macos/scripts/ensure_ghostty_artifacts.sh --publish-missing`, so release builds consume a valid prebuilt artifact release when available and build plus publish from the pinned submodule when the release is absent. For uncommitted local Ghostty experiments, use `apps/macos/scripts/setup_ghostty.sh --build --allow-dirty`; the generated manifest records the dirty source state and must not be used for PR or release workflows.

To validate the real in-process Ghostty owner renderer path in `SpacesApp`, launch the app normally with an isolated database root:

```bash
apps/macos/scripts/setup_ghostty.sh --build --allow-dirty
export SPACES_DB_PATH="$TMPDIR/spaces-ghostty-owner/spaces.db"
mkdir -p "$(dirname "$SPACES_DB_PATH")"
pkill -x SpacesApp 2>/dev/null || true
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/SpacesApp
```

When the app launches built-in Spaces terminals itself, `spacesd` owns the session and native owner windows attach through the service control socket. Use the normal app flows:
- Open a workspace terminal from the workspace detail pane.
- Launch a workspace process while the configured terminal host is `Spaces`.
- Run a coding-agent command in a workspace terminal so it registers as a coding-agent row.

Close one of those owner windows and reopen it from the app. Quit and relaunch `SpacesApp`, then reopen the same session from the app. The shell or long-running process should stay attached to the same service-owned Ghostty session without restarting.
CLI-created sessions such as `spaces terminal create` and CLI-managed `spaces workspace start --workspace <id>` use the same daemon-owned render-frame stream. The service publishes live Ghostty render frames to native client windows over the per-session subscription socket, while `output.log` remains the `spaces terminal tail` source.
For scripted real-system checks against the running app, `spacese2e` exposes `open-workspace-terminal`, `run-workspace-process`, and `start-workspace-terminal-session` so the manual harness can exercise the same app launch path without accessibility scripting.

To verify the embedded Ghostty backend on an isolated database root:

```bash
export SPACES_DB_PATH="$TMPDIR/spaces-ghostty/spaces.db"
export SPACES_RUNTIME_DIR="$(dirname "$SPACES_DB_PATH")/runtime"
apps/macos/scripts/setup_ghostty.sh
env SPACES_DB_PATH="$SPACES_DB_PATH" SPACES_RUNTIME_DIR="$SPACES_RUNTIME_DIR" apps/macos/.build/debug/SpacesApp
mkdir -p "$TMPDIR/spaces-ghostty/workspace"
env SPACES_DB_PATH="$SPACES_DB_PATH" SPACES_RUNTIME_DIR="$SPACES_RUNTIME_DIR" apps/macos/.build/debug/spacese2e \
  register-project --project-dir "$TMPDIR/spaces-ghostty/workspace" >/dev/null
spaces_cli="$(cd apps/macos/.build/debug && pwd)/spaces"
(cd "$TMPDIR/spaces-ghostty/workspace" && env SPACES_DB_PATH="$SPACES_DB_PATH" SPACES_RUNTIME_DIR="$SPACES_RUNTIME_DIR" "$spaces_cli" \
  terminal create --command cat --title verify-ghostty)
env SPACES_DB_PATH="$SPACES_DB_PATH" SPACES_RUNTIME_DIR="$SPACES_RUNTIME_DIR" apps/macos/.build/debug/spaces terminal list
env SPACES_DB_PATH="$SPACES_DB_PATH" SPACES_RUNTIME_DIR="$SPACES_RUNTIME_DIR" apps/macos/.build/debug/spaces \
  terminal send text <session-id> "hello from ghostty" --submit
env SPACES_DB_PATH="$SPACES_DB_PATH" SPACES_RUNTIME_DIR="$SPACES_RUNTIME_DIR" apps/macos/.build/debug/spaces \
  terminal send bytes <session-id> 13
env SPACES_DB_PATH="$SPACES_DB_PATH" SPACES_RUNTIME_DIR="$SPACES_RUNTIME_DIR" apps/macos/.build/debug/spaces \
  terminal tail <session-id> --lines 5
env SPACES_DB_PATH="$SPACES_DB_PATH" SPACES_RUNTIME_DIR="$SPACES_RUNTIME_DIR" apps/macos/.build/debug/spacese2e \
  mobile-status
env SPACES_DB_PATH="$SPACES_DB_PATH" SPACES_RUNTIME_DIR="$SPACES_RUNTIME_DIR" apps/macos/.build/debug/spaces \
  terminal show <session-id>
```

For built-in terminal verification, keep exactly one `SpacesApp` process running for the chosen profile root. The current `ghostty-embedded` slice keeps live Ghostty rendering owner-only on both macOS and iOS. Opening a terminal window or mobile detail view auto-attempts takeover, live non-owner states show takeover or status UI only, and ended sessions may still show the final Ghostty render when it was persisted.

If Ghostty owner or mirror setup reports `ghostty_session_new_headless failed` or `ghostty_mirror_new failed`, inspect for stale debug daemons before rerunning. Stop only current-worktree or preserved E2E-profile processes: use `pgrep -af 'SpacesApp|spacesd|spacese2e|xcodebuild|e2e|mobile-demo'`, confirm each candidate with `ps eww -p <pid> -o pid,ppid,command`, and kill only processes whose executable and `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR` belong to the current checkout or a preserved E2E run root. Leave other worktree profiles running. libghostty reports why it refused a session only under `GHOSTTY_LOG=stderr`; when the reason points at the artifacts themselves rather than the environment, `apps/macos/scripts/setup_ghostty.sh --build` rebuilds them from the pinned submodule.

For maintained simulator E2E coverage of the mobile terminal path:

```bash
apps/macos/Tests/e2e.sh mobile
```

The mobile lane builds the macOS debug products once, builds the iOS app and UI tests once with `xcodebuild build-for-testing`, launches one daemon-backed simulator demo stack with local Harbor and Lantern workspaces, and then runs selected scenarios against that stack. Use `--list` to print scenarios, `--scenario <name>` to run one or more scenarios, and `--keep-root` to preserve the shared demo root. The `ownership-guard` scenario covers the control-plane ownership checks: viewer input is rejected, takeover enables mobile input, Mac retakeover removes mobile ownership, and mobile input is rejected again.

The E2E helpers source the worktree `.env` (gitignored, at the repo root) via `scripts/spaces-e2e-env.sh` when it exists. Local-only scenarios run without `.env`; remote-host lanes require it. A working remote test host is configured in the primary checkout's `.env`; a fresh worktree has none, so copy it in to run remote lanes from that worktree:

```bash
cp ~/projects/spaces/.env .env
```

The remote keys it provides are `SPACES_E2E_REMOTE_SSH_HOST`, `SPACES_E2E_REMOTE_SSH_USER`, `SPACES_E2E_REMOTE_SSH_PORT`, `SPACES_E2E_REMOTE_DAEMON_HOST`, `SPACES_E2E_REMOTE_WORKSPACE_ROOT`, `SPACES_E2E_REMOTE_GIT_ROOT`, `SPACES_E2E_REMOTE_HOST_ID`, `SPACES_E2E_REMOTE_NAME`, and `SPACES_E2E_REMOTE_AUTH_TOKEN`. They drive the remote Device API lanes (`apps/macos/Tests/e2e.sh device-api remote` / `latency-compare`), the `spacese2e profile --remote` commands, and the Linux daemon deploy/cleanup scripts. A remote daemon's port is a fact the profile records for itself rather than something configured here, and a remote profile root is derived from the local profile name, so `SPACES_E2E_REMOTE_DAEMON_PORT` and `SPACES_E2E_REMOTE_DEVICE_ROOT` are read by nothing — a `.env` copied from an older checkout can still carry them. Never commit `.env`.

Each `apps/macos/Tests/e2e.sh` invocation writes an ignored Markdown report under `apps/macos/.artifacts/e2e-runs/<timestamp>-<lane>/summary.md`. The run directory stores collected metric artifacts as flat step-prefixed files alongside the report. The report includes the command timeline, per-case timing table, per-step logs, flattened tables for collected JSON metrics and result files, TSV tables for app metric/result logs, and links to raw JSONL performance logs.

`apps/macos/Tests/e2e.sh all` is the shared-setup smoke lane for app, terminal, mobile, and paired-device coverage. `apps/macos/Tests/e2e.sh exhaustive` is the full manual lane: app full coverage, every terminal scenario, every mobile scenario, local and constrained iOS latency profiles, local and remote Device API parity, and Device API profiling.

`apps/macos/.build/debug/spacese2e e2e app --scenario window-cycle-small` runs the compact app-side window-cycle profile. The scenario includes the local primary workspace and, with the repo `.env` remote host configuration, a paired remote workspace. The remote portion opens a configured process pane and an ad hoc terminal pane on the Mac client, records sidebar direct-focus latency for the already-open process pane, and records cycle latency between the two already-open remote terminal panes.

Mobile terminal latency sweeps target the local paired daemon over the Device API; remote terminal latency runs through the paired-device parity harness instead of a separate direct-daemon channel.

The daemon-hosted Device API is a paired Spaces-only transport rather than a third-party external API surface. `spacese2e mobile-serve` is available when a harness needs a standalone Device API process with explicit host, port, or one-time pairing-window output; harness JSON calls go through `spacese2e mobile-request` so local scripts use the same pinned-TLS transport as the iOS app.

`apps/macos/Tests/e2e_remote_terminal_send.sh` verifies the orchestrator agent path end to end against the configured remote host: it pairs the CLI over SSH with `spaces device pair`, creates a remote terminal session, and drives it from the Mac with `spaces terminal list --device`, `spaces terminal send text --device`, and `spaces terminal tail --device`, using an isolated client database and secret directory. The remote daemon must be on the same wire-protocol version as the local build (redeploy with `apps/macos/scripts/deploy_linux_spacesd_e2e.sh` first).

Focused paired-device parity checks use one shared Device API flow for local and remote daemons:

```bash
apps/macos/Tests/e2e.sh device-api local
apps/macos/Tests/e2e.sh device-api remote
```

Both targets create a project and workspace through the paired daemon, open and stop a workspace terminal, run/restart/stop a configured process, and stop a live coding agent. During the terminal portion, the parity flow writes `terminal-latency-summary.json` with open-terminal request timing, state-readiness timing, send-to-state-progress samples, state request timing, and state progress counters. The remote target installs its test daemon as its own `remote-device-e2e` development profile, so the remote account's installed profile is untouched; it reads that profile's assigned Device API port back out of the profile's `device-api.json` rather than choosing one, drives the daemon through the profile's own CLI, relies on the Linux installer enabling user lingering, and verifies the daemon remains reachable from the Mac after the setup SSH command exits; it does not keep a persistent SSH session open for service lifetime. The remote target also verifies the Device API service tunnel: `spacese2e service-tunnel` performs an HTTP GET through the paired daemon to the workspace's running `web` service, and a request for a missing service must fail with `notFound`. `apps/macos/Tests/e2e.sh device-api` runs local and remote parity.

Focused remote terminal latency comparisons use the configured `.env` remote host, create one remote Device API workspace, and compare Device API workspace-terminal latency against a local Spaces terminal that SSHes into the same remote workspace directory:

```bash
apps/macos/Tests/e2e.sh device-api latency-compare --samples 12 --keep-root
```

The comparison writes `remote-terminal-latency-compare-summary.json` with Mac- and iOS-labeled input echo, command output, and scrollback scenarios. Each scenario reports p50/p95/max event-to-visible timings for `remote-workspace` over `device-api-request-session+subscribe` and `local-workspace-ssh` over the local terminal subscription socket, plus p95 delta and ratio. Input and command-output probes wait for decoded render text markers that are not present in the typed command, so local PTY echo does not satisfy remote-output measurements. Scrollback probes create a deterministic large scrollback fixture, verify that repeated scroll controls can reach top and bottom sentinels, wait for the setup output stream to go idle, and then require a decoded stream payload with `reason=scroll`, so pending command output does not satisfy scroll measurements. The summary includes all-sample and steady-state timings, control-request and response-to-stream phase summaries, request-session write/response/decode splits, local socket splits, stream emitted-to-received wall-clock estimates, grouped remote daemon performance events, per-scenario remote event groups, derived same-host timeline deltas such as send-control-to-output-stream and scroll-dispatch-to-stream-send, and the Device API state-polling baseline from the paired remote setup probe. The preserved run root also contains the raw remote daemon `remote-device-performance.jsonl` copied from the Linux service when the comparison installs that profile with `install.sh --performance-log`.

Remote Device API runs cache the Linux daemon archive under `apps/macos/.build/linux-e2e-cache/artifacts/` using a source fingerprint, skip re-upload when the remote archive checksum already matches, and reuse the installed remote daemon when the artifact checksum and Device API port marker match and the daemon is healthy.

`apps/macos/scripts/deploy_linux_spacesd_e2e.sh --profile NAME` is the one entry point that builds, caches, and uploads that archive; every lane that installs a Linux daemon goes through it and names the profile it installs into. That name keys the remote staging directory (`~/.spaces/remote-artifact-e2e/<profile>/`, and the tree the archive is extracted into beside it), so deploys aimed at different profiles of the same account never clear or overwrite each other's staging tree. The name `installed` is refused: the installed profile is the lane paired clients talk to and carries release builds only, so every lane — the mobile demo included — installs its source build into a development profile of its own (`~/.spaces-dev/profiles/spaces/<name>/`, the `spacesd@<name>` systemd instance, and a Device API port that profile's daemon assigns itself).

The fingerprint covers `Package.swift`, `Package.resolved`, the artifact build script, the builder image definition, and the source directories of the `spacesd` and `spaces` dependency closure — the only targets the Linux build compiles. That closure is derived from `Package.swift` at fingerprint time, so adding a target or rewiring a dependency needs no edit; only directories the manifest declares as targets outside the closure (the AppKit/SwiftUI client targets) are left out, and every other entry under `Sources` is included, which covers targets the macOS manifest does not declare at all. A macOS-only change is therefore a cache hit rather than a rebuild whose artifact would have been byte-identical.

Linux daemon-side unit suites (the `#if os(Linux)` tests in `spacesterminalcoreTests` and `spacesterminalghosttyTests`, plus `SpacesTestHostDetectionTests`, which is cross-platform because test-host detection rests on a different signal per platform) run inside Docker via `apps/macos/scripts/run_linux_tests.sh`:

```bash
docker run --rm --init --platform linux/amd64 \
  -v "$PWD":/workspace \
  -v spaces-linux-src:/root/src \
  -v spaces-linux-zig:/root/spaces-zig-cache \
  -v spaces-linux-test-build:/root/spaces-test-build \
  -e ZIG_LOCAL_CACHE_DIR=/root/spaces-zig-cache/local -e ZIG_GLOBAL_CACHE_DIR=/root/spaces-zig-cache/global \
  swift:6.2-noble \
  bash /workspace/apps/macos/scripts/run_linux_tests.sh
```

On Linux the package manifest declares only the daemon-side graph (the targets the artifact ships plus those two test targets), because `swift test` builds every declared target and the AppKit/SwiftUI client targets do not exist there. The script stages sources onto container-native filesystem first: resource copies from the bind mount fail with EINTR under the amd64 runner, and the staged tree keeps container paths stable so the build scratch volume stays incremental. Linux test suites use Swift Testing rather than XCTest — corelibs-xctest deadlocks an async test before its first line ever runs (the test job queues to run while XCTest's blocked main thread polls in a loop that never drains it), whereas the swift-testing runner starts from an async main and drains queued work correctly. Each suite runs in its own `swift test --filter` invocation because `.serialized` only orders tests within a suite, and every suite here mutates the process-wide `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR` in its init/deinit — two such suites in one run would clobber each other's environment. Each invocation is checked for a zero-match run and fails the lane when the named suite matched nothing: `swift test --filter` exits 0 in that case, so a suite whose source the Linux test target does not compile would otherwise sit in the list running no tests while the lane stays green. A Linux suite therefore belongs both in that filter list and in the Linux `sources:` whitelist for its test target in `Package.swift`.

Every artifact build runs inside the Spaces Linux builder image, which carries the Swift base toolchain, the packages the build needs, and the pinned Zig toolchain, so a container starts compiling instead of provisioning itself and no build downloads Zig onto the workspace. `apps/macos/scripts/ensure_linux_builder_image.sh --arch <arch>` prints the image tag and builds the image first when the machine does not have it; `apps/macos/scripts/linux-builder-versions.sh` holds the base image, package list, and Zig version that define it. The tag is a digest of that definition, so changing any of it names a different image and the next build provisions it, and every worktree on the machine shares one image. A republished upstream base tag does not change the digest — `docker rmi` the tag to pick one up.

The lower-level Linux artifact build command is:

```bash
docker run --rm --init --platform linux/arm64 \
  -v "$PWD":/workspace \
  -v spaces-linux-zig:/root/spaces-zig-cache \
  -v spaces-linux-swift:/root/spaces-swift-cache \
  -w /workspace \
  -e ZIG_LOCAL_CACHE_DIR=/root/spaces-zig-cache/local -e ZIG_GLOBAL_CACHE_DIR=/root/spaces-zig-cache/global \
  -e SPACES_LINUX_SWIFT_BUILD_PATH=/root/spaces-swift-cache/build -e SPACES_LINUX_SWIFT_CACHE_PATH=/root/spaces-swift-cache/cache \
  -e SPACES_LINUX_SWIFT_CONFIG_PATH=/root/spaces-swift-cache/config -e SPACES_LINUX_SWIFT_SECURITY_PATH=/root/spaces-swift-cache/security \
  "$(apps/macos/scripts/ensure_linux_builder_image.sh --arch arm64)" \
  bash -lc 'apps/macos/scripts/build_linux_spacesd_artifact.sh --arch arm64'
```

The zig and SwiftPM cache/build paths must live in named Docker volumes, not on the bind-mounted workspace: lock acquisition over Docker Desktop's macOS file sharing can deadlock the ghostty-vt `zig build` (workers park in `futex_wait` with finished compile children unreaped and container CPU pinned at 0%). Named volumes live on the Docker Desktop Linux VM's own filesystem where POSIX locking works, and they persist across runs so caches survive between builds. Sources are read from the mount and the artifact is written back to `dist/linux/` on the mount; only lock-holding state stays in the volumes.

Use `--platform linux/amd64` with `--arch x86_64` for the Ubuntu x86_64 artifact; matching the two is what the build checks first. Both architectures build locally on an Apple Silicon Mac — the x86_64 leg runs under emulation and takes a few minutes longer, smoke test included. The archive contains `bin/spacesd`, `bin/spaces`, `install.sh`, the `spacesd-bin` executable, `libghostty-vt`, and the Swift runtime libraries needed on stock Ubuntu 24.04.

A failure that reproduces only on CI's x86_64 runners — not locally, where Docker's amd64 leg runs under emulation on a machine with far more cores — is hunted on a disposable GCP VM matching the runner's exact shape instead of by looping CI. `gcloud compute instances create <name> --machine-type=e2-standard-4 --image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud --boot-disk-size=60GB --max-run-duration=8h --instance-termination-action=DELETE` gives a native 4-vCPU x86_64 box for ~$0.13/hour that deletes itself even if forgotten; install `docker.io`, tar-pipe the worktree over `gcloud compute ssh` (the Linux test lane needs `apps/macos/.local/ghosttyvt/include` and `lib-linux` alongside the sources), and loop the documented `run_linux_tests.sh` docker invocation under `setsid nohup`. Iterations run in tens of seconds instead of a CI round-trip per sample, which is what makes probabilistic failures measurable: establish the failure rate, change one thing, measure again. The VM's host root can attach `gdb -p <pid>` into a container (`-ex "set sysroot /proc/<pid>/root"`) for a userspace backtrace of a wedged process — evidence no in-container diagnostics can produce once the process is deadlocked. Operational sharp edges, each of which has silently voided a run: a trailing `… & tail` in a `gcloud compute ssh` command backgrounds the whole preceding `tar && …` chain and reconnects its stdin to `/dev/null`, so sync steps must run as their own foreground ssh invocations and every sync is verified by `grep`-ing a marker on the VM before trusting the next run; `pkill -f` inside an ssh command self-matches when the plain pattern text appears elsewhere in that same command line; `timeout` around `docker run --sig-proxy=false` needs `-k`, because the CLI ignores SIGTERM in that mode (the SIGKILL path exits 137, not 124); and long runs are checked actively rather than awaited — an in-container `apt-get` once hung for hours producing no output at all.

The Linux `zig build` passes `-Dcpu=baseline` so `libghostty-vt` runs on every device of the artifact's architecture rather than only on CPUs as capable as the machine that built it. It is a native build, and a Zig target query naming neither an architecture nor a CPU compiles for the build host's own CPU: on an AVX-512 runner that puts EVEX-encoded instructions in the library and the daemon takes a `SIGILL` allocating its first terminal page on every device without AVX-512. Nothing observes this from a build lane — an amd64 build under emulation on an Apple Silicon Mac resolves a CPU without AVX-512, and the CI smoke test runs on the runner that just compiled the code — so packaging asserts the property on the artifact instead: the x86_64 build fails if any binary it compiled decodes an EVEX instruction. That check reads the encoding (`0x62` leads no other 64-bit instruction) rather than a CPU feature list, because the SIMD kernels Highway compiles for AVX2 and SSE4 are selected by a runtime CPUID check and are meant to be there. Ghostty's Apple targets already resolve a generic CPU, so the macOS and iOS builds need no equivalent flag.

The bundled `install.sh` takes `[--profile NAME] [--performance-log PATH]`, and those arguments alone decide what it installs. It ignores the installing shell's `SPACES_DB_PATH`, `SPACES_RUNTIME_DIR`, `SPACES_DEVICE_API_HOST`, `SPACES_DEVICE_API_PORT`, and `SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH` entirely: inheriting them is what let one developer's worktree profile get baked into the device's single shared unit, pinning the installed daemon and every later deploy to that one profile. With no arguments it installs the device's one installed profile — the release lands under `~/.spaces/daemon/releases/<version>/`, `~/.spaces/daemon/current`, `~/.spaces/bin/spacesd` and `~/.spaces/bin/spaces` follow it, `~/.local/bin/spaces` points at the managed CLI helper, it creates `~/.spaces/runtime`, `~/spaces/workspaces`, and `~/spaces/repos`, and it installs `~/.config/systemd/user/spacesd.service`. With `--profile NAME` everything that profile owns instead lives under `~/.spaces-dev/profiles/spaces/NAME/`, its stable daemon path is `daemon/current/bin/spacesd` inside that root, nothing under `~/.spaces` is written and no `~/.local/bin` alias is created, and the daemon runs as the `spacesd@NAME.service` instance of one shared `~/.config/systemd/user/spacesd@.service` template. That template is rewritten on every install, which is safe because it carries no per-profile content — no `Environment=` lines at all; the instance name resolves the path and the binary there resolves the rest. `--performance-log PATH` is the one per-instance setting and arrives as a `<unit>.d/performance-log.conf` drop-in for the target unit, removed again by any install that does not pass the flag so the capability never lingers as ambient state. Either way the installer enables user lingering so the service survives SSH disconnects, and enables the target unit. An already-running compatible daemon applies the installed image through the exec-in-place handoff, driven through the target profile's own `spaces` binary so only that profile's daemon is touched. The installer verifies the preserved pid and installed executable; an installed image that is still replaying sessions after the readiness deadline is left running, and any accepted handoff that has not execed by the deadline fails non-destructively. Systemd starts the service only when no daemon pid exists. The Docker artifact smoke test verifies the same handoff through its resume marker when Docker Desktop's amd64 Rosetta runner exposes the translator rather than the guest executable through `/proc/<pid>/exe`. If the Linux account cannot enable lingering itself, run `sudo loginctl enable-linger <user>` on the Linux device and retry.

The single user-facing Linux install/upgrade path is `scripts/spaces-install-linux.sh`, served at `https://usespaces.dev/install.sh`. `apps/web`'s npm `prebuild` step copies the script into `apps/web/public/install.sh`, so every Firebase website deploy republishes the current installer; the script is not uploaded as a per-release GitHub asset. The script takes an optional version argument, run on the Ubuntu 24.04 device:

```bash
curl -fsSL https://usespaces.dev/install.sh | bash
```

installs the latest release. A version-pinned form:

```bash
curl -fsSL https://usespaces.dev/install.sh | bash -s -- <version>
```

installs a specific released version; the Mac app and CLI print this form when pairing needs a daemon wire-compatible with that client.

The no-version form resolves the latest release through GitHub's `releases/latest/download` redirect, which only works while Spaces releases hold the repo's "latest" marker: the release workflows create Spaces releases with `--latest`, and `ensure_ghostty_artifacts.sh` publishes `ghostty-artifacts-<sha>` releases as prereleases so internal artifact releases never capture `releases/latest`.

For development or debugging against an unreleased build, install a locally built artifact on a reachable Linux device with scp plus the bundled `install.sh` (this is the offline alternative to the published one-liner):

```bash
scp .build/artifacts/spacesd-ubuntu-24.04-x86_64.tar.gz <host>:/tmp/
ssh <host> 'mkdir -p /tmp/spacesd-install && tar -xzf /tmp/spacesd-ubuntu-24.04-x86_64.tar.gz -C /tmp/spacesd-install && /tmp/spacesd-install/install.sh'
```

After install, verify the remote pairing command over strict SSH — the Mac app's `--ssh` pairing path runs the same command to fetch the remote pairing link:

```bash
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes <host> '~/.spaces/bin/spaces device pair --json'
```

Remote Macs are installed from the signed DMG instead of a headless artifact. The DMG install creates `/Applications/Spaces.app`, links `/usr/local/bin/spaces`, `/usr/local/bin/spacesd`, and `/usr/local/bin/spaces-caddy` to `Spaces.app/Contents/Resources/`, links `~/.spaces/bin/spaces` and `~/.spaces/bin/spacesd` to the same bundled binaries, writes the per-user LaunchAgent with `~/.spaces/bin/spacesd` as its program, and creates the default `~/.spaces` state directories. When a remote Mac has no Spaces install, pairing fails with guidance to install the Spaces app.

For focused terminal latency probes:

```bash
apps/macos/Tests/e2e.sh terminal --list
apps/macos/Tests/e2e.sh terminal --scenario mac-input-latency
apps/macos/Tests/e2e.sh terminal --scenario mac-scrollback-latency
apps/macos/Tests/e2e.sh terminal --scenario mac-scrollback-partial-latency
apps/macos/Tests/e2e.sh terminal --scenario mouse-reporting-scroll
apps/macos/Tests/e2e.sh mobile --scenario ios-input-latency --network-profile local
apps/macos/Tests/e2e.sh mobile --scenario ios-input-latency --network-profile ios-constrained
apps/macos/Tests/e2e.sh mobile --scenario ios-scrollback-latency --network-profile local
apps/macos/Tests/e2e.sh mobile --scenario ios-scrollback-latency --network-profile ios-constrained
```

The latency scenarios are fast performance iteration lanes rather than the canonical correctness gate. They write `terminal-latency-summary.json`, print p50, p95, max, per-sample timings, visible render frame mix, median visible render-update bytes, and render payload rates. Input scenarios fail on gross latency regressions, render-frame decode failures, or measured typed echoes that arrive as full, missing, or `explicit_resync` frames instead of live stream deltas; report-only targets stay visible in the terminal output. Input summaries include enqueue-to-RPC-begin, RPC duration, frame-apply or frame-publish timing, RPC-end-to-render-visible, and event-to-visible totals. Mac probes target the debug app by executable name; the gated total for every mac scenario runs from the host's own record of receiving the input to the client applying the resulting frame, with scroll gestures alternating direction across samples and command catchup driven from one warmed shell session. The catchup probe types the command and waits for the typed line to render before pressing Return, so the timed window contains the command's own frames rather than the tail of the echo; the typing and that wait precede every reported phase, including the RPC duration. One Return produces a burst of exports as the line break, the command output, and the redrawn prompt arrive, so the catchup total ends at the apply of the last revision exported before the output was seen and reports the first frame apply alongside it. Both ends of a gated total are instrumented events, and every apply is paired to its host export by revision so the phase split describes one frame's trip to the client. The two totals that bracket the gated one are reported and never gated: the total measured from the harness's clock starts before the probe spawns the `spacese2e` CLI and so carries process startup and IPC, which is reported on its own as the event-to-host-input phase, and the event-to-visible total ends at a polled subprocess, so it carries the host's scheduler delay and moves by more than 100ms with load unrelated to Spaces. A gated metric must also resolve for every attempt, with nothing excused from the denominator; a run that resolves it for only some samples fails as a harness defect rather than reporting a percentile over the attempts that happened to work. A scroll attempt whose screen never changes is a failure, and the harness records whether the host exported a frame for it so the two shapes are distinguishable: no export means the gesture never reached the terminal, and an export means it did and the screen still did not move. Each apply is matched at or above its export's revision rather than equal to it, because the client's apply mailbox collapses frames that queue together and applies only the newest. `mac-scrollback-latency` uses large scroll deltas and `mac-scrollback-partial-latency` uses smaller within-screen deltas. Mac summaries also split the gated total into host input to frame export, frame export to mirror apply, and frame apply to dumped-state visibility. Host input to screen state change is reported beside them as a host signal rather than a phase of that total: a keystroke exports on the output write first, at the revision before ghostty's screen callback runs, so the state change lands after the frame the gate pairs, and a viewport scroll produces no screen state change at all and leaves it empty. Mobile summaries split host publish to relay read, relay read to network send begin, network send begin to stream-visible, full versus delta visible sample counts, and average plus peak stream bytes per second. Scrollback summaries measure rendered text changes, unrendered gesture counts, and render cadence as report-only metrics. The `ios-constrained` mobile profile shapes standalone Device API requests with `80ms` RTT, `8Mbps` bandwidth, and `16KB` chunks; normal terminal stream frames remain ordered but are not per-frame delayed by the shaper. Shaping is selected through the test-only `SPACES_DEVICE_API_NETWORK_PROFILE` environment variable, which standalone Device API runs read; the daemon-supervised Device API path always uses the default local profile.

For render-update profiling, run the latency scenario with a fixed sample count, terminal size, fixture command, target, and network profile. The scenarios exercise the production v2 stream: self-contained full v2 updates for initial baselines, state fetches, and resyncs, plus delta updates with native scroll-rectangle operations for steady output, live `state_change`, and scrollback.

```bash
apps/macos/Tests/e2e.sh mobile --scenario ios-input-latency --network-profile local --samples 12 --keep-root
```

Summarize each preserved `mobile-terminal-performance.jsonl` or `terminal-performance.jsonl` with the latency summary JSON from the same work root. Render-update summaries report total selected payload bytes plus split fields for network send bytes, local publish/receive render-update bytes, materialized render-update bytes, frame-kind byte totals, fallback reasons, and drop reasons:

```bash
apps/macos/Tests/render_update_profile_summary.py \
  --performance-log <work-root>/mobile-terminal-performance.jsonl \
  --summary-json <work-root>/terminal-latency-summary.json \
  --render-mode production \
  --sample-count 12 \
  --network-profile local \
  --target ios-input-latency
```

The summarizer copies the raw JSONL log and writes normalized JSON under `apps/macos/.artifacts/terminal-render-profiles/`, an ignored output directory. Each summary records git SHA, Ghostty submodule SHA, render mode, terminal size, sample and warmup counts, fixture command, network profile, target, timestamp, byte totals, average bytes per update, peak 1s and 10s bandwidth, frame mix, scrollRect delta byte totals, output-to-visible latency percentiles, encode/decode/apply CPU-proxy totals, and drop/resync/refresh counts.

For direct CLI verification of Spaces terminal commands:

```bash
apps/macos/Tests/e2e.sh terminal --scenario cli
```

That scenario exercises `spaces terminal create`, `send`, `key`, `tail`, `show`, and both takeover directions against one isolated Spaces terminal session.

For the daemon's exec-in-place update handoff:

```bash
apps/macos/Tests/e2e.sh terminal --scenario daemon-exec-handoff
```

`e2e_daemon_exec_handoff.sh` launches a directly-supervised `spacesd` behind a `bin/spacesd` symlink, starts a long-lived shell session printing a marker then a steady tick output, flips the symlink to a second on-disk copy of the same build, and pokes the daemon with `spaces daemon apply-update`. It proves the daemon pid is unchanged (exec, not a supervisor respawn), the session's child pid survives, the expected `handoff_resume generation=N` line lands in the daemon log, the pre-handoff scrollback marker is still in `terminal tail`, live I/O keeps flowing (a freshly sent line round-trips), and no runtime state lands `.failed`. It repeats the flip-and-poke a second time to also cover a double handoff (`generation=2`) before a normal idle shutdown.

For a plain SIGTERM to the daemon:

```bash
apps/macos/Tests/e2e.sh terminal --scenario daemon-signal-shutdown
```

`e2e_daemon_signal_shutdown.sh` launches a directly-supervised `spacesd`, starts a long-lived session, and sends `SIGTERM` to the daemon pid directly rather than going through the control socket. It proves the daemon logs the signal, exits, and — the discriminating check — the session's `terminal_runtime_states` row is finalized to `exited` rather than left stuck at `running`, which is only true if the signal ran the same graceful teardown (transcript flush, attachment finalization, durable runtime-state write) as the `.shutdown` command.

For the coding-agent orchestration surface (`spaces agent` list/status/annotate/subscribe/kill and notification injection):

```bash
apps/macos/Tests/e2e.sh terminal --scenario agent-orchestration
# or directly:
apps/macos/Tests/e2e_agent_orchestration.sh
```

`e2e_agent_orchestration.sh` is a daemon+CLI test (no app, desktop control, or hotkeys) that drives this checkout's own `spaces`, `spacesd`, and `spacese2e`, each of which resolves the worktree profile from its own location, so it only ever drives this checkout's daemon and never another worktree's. Its always-runnable Part A opens two ordinary shell sessions and drives the lifecycle with explicit `spaces agent signal` events (spawn gates on installed hooks, so the core flow is exercised without real agents): it asserts that `init` produces a ready agent row, an annotation survives a later `working` signal, a `subscribe` + `blocked` injects the `[spaces] … is blocked … open: spaces://terminal/<id>` line into the subscriber's tail, a `done` for a busy subscriber is queued and then flushed when the subscriber goes idle, a cycle-closing subscribe is rejected, `kill` removes the row, and a nonexistent session id is a loud error. Part A then covers the two `agent spawn` behaviors that need no real agent: a spawn whose command cannot run fails in well under the detection budget naming the child's exit, and a spawn of a fixture binary named after a supported agent is detected and inherits the interactive-login PATH (the entries a login shell adds only when interactive; a machine that adds none says so instead of asserting nothing). Its last step covers the hookless exit (the case codex and opencode leave to the daemon's foreground reconciler) without a real agent: a `codex`-named symlink to `sleep` runs in an interactive login shell, so foreground detection classifies it exactly as the real CLI, and quitting that process asserts the watching terminal received exactly one `is exited` block, that the block names `(codex)` rather than the anonymous `coding agent`, and that `agent_session_events` holds exactly one reconciler `exit` for the child. Part A cleans up the sessions it creates and leaves the shared daemon running.

Set `SPACES_E2E_AGENT_MATRIX=1` to also run the opt-in provider matrix (Part B), which is skipped by default:

```bash
SPACES_E2E_AGENT_MATRIX=1 apps/macos/Tests/e2e_agent_orchestration.sh
```

For each provider (`claude`, `codex`, `opencode`) whose binary is on `PATH` and whose Spaces hooks are current, Part B spawns the agent, records a `provider=… first_signal_observed=… ready_ms=… sequence=…` report line from `agent status --json` polling, submits a trivial prompt (text then carriage return), and kills the session. It installs nothing: a provider whose binary is missing or whose hooks are not current is reported as `SKIP` (the loud spawn hook-gate error), leaving the user's real agent configs untouched. Skips do not fail the run; any attempted provider that fails makes the script exit non-zero.

For the scheduled-automations command surface (`spaces` `automation-create`/`-update`/`-delete`/`-list`/`-runs`/`-trigger`/`-cancel`/`-end-agents`, exposed through `spacese2e` rather than `spaces` itself):

```bash
apps/macos/Tests/e2e_automations.sh
```

`e2e_automations.sh` is a daemon-only test (no app, desktop control, or hotkeys) that binds to the current worktree profile from `spacese2e profile-show --shell`, so it only ever drives this checkout's daemon and never another worktree's; the daemon autolaunches on the first profile command. It registers a fixture project and targets its default workspace through `spacese2e automation-*` — the same profile-socket commands the app's Automations UI sends — as the seam for authoring automations in tests, since there is no `spaces automation` CLI surface for end users. Scenarios a-e use fast fake scripts (`--script`), never a real coding agent: a manual automation whose script writes a marker and exits 0 runs to `succeeded` with the marker in its output and the run's terminal session stamped with `kind=automation`, the run id, and the fixture workspace id; a script that exits 3 runs to `failed` with that exit code; a `concurrency=skip` automation triggered while a run is still sleeping records a `skipped(concurrency)` row for the second trigger, then canceling the sleeping run leaves it `canceled`; a 2-second timeout against a longer sleep lands `timed_out`; and a `SPACES_AUTOMATION_RUN_ID` attribution check confirms the run's own workspace-bound session carries the run id. Scenario f drives what an `agent`-kind (`--kind agent`) run can exercise without a real provider: a supported command (`claude`, so the spawn command gate passes) targeting a workspace id that does not resolve fails cleanly with no attributed agents, and End-agents on that terminal run is confirmed to be an accepted no-op that leaves it `failed`. The rest of the agent-kind lifecycle — spawn, foreground detection, prompt delivery, `done` completion, ending a lingering live agent — needs a real coding agent binary to reach foreground detection (a fixture script's foreground process resolves to its shebang interpreter, never the agent name it's disguised as, so it can never be detected), so that path is covered by `workspacecoreTests/AutomationServiceTests` instead. The script deletes every automation it creates on exit, which also cancels any still-running run and cleans up its artifacts.

To exercise a cron schedule locally rather than triggering manually, create the automation with a `--cron` expression a minute or two out (`spacese2e automation-create --trigger cron --cron '<minute> * * * *' ...`) and poll `automation-runs --automation-id <id>` until the fire lands, instead of waiting on a long-period expression.

The Spaces terminal `tail` path also depends on the local `libghostty-vt` artifacts. Set them up before building or profiling terminal changes:

```bash
apps/macos/scripts/setup_ghostty.sh
```

The setup script installs Zig `0.16.0` under `apps/macos/.local/ghosttyvt/toolchain/` when a source build is requested. Ghostty pins source dependencies by content hash, and setup leaves Zig package caches unmodified so cold and warm caches build the same source. The fork keeps `main` mirrored from upstream, so the reviewable fork delta lives in the `spaces -> main` pull request.
For a browser view of fork drift against upstream, open [ghostty-org/ghostty compare view](https://github.com/ghostty-org/ghostty/compare/main...yogesh-dhande:ghostty:spaces).
The GitHub Actions PR and release workflows run this setup before the macOS build and coverage pass so clean runners have the matching `GhosttyKit`, `libghostty-vt` headers, and dylib available.

Terminal E2E, profiling, and soak scenarios that launch `SpacesApp` acquire a shared harness lock before they launch a profile-owned app instance. They stop only the app instance for their own profile. Hotkey-sensitive and real-system desktop-control workflows also wait for desktop-global control instead of killing unrelated running Spaces instances. When desktop control is already owned by another Spaces instance, the wait path also posts a macOS notification that asks you to close the running app when you are done with it.

For repeatable profiling of the built-in terminal owner and ownership-transfer flows:

```bash
apps/macos/Tests/e2e.sh terminal --scenario built-in-terminal-profile --samples 3
```

The profiler runs against an isolated `SPACES_DB_PATH`, enables `DEBUG=1`, exercises owner attach, remote viewer attach, send, `tail`, and takeover, then summarizes the built-in terminal perf metrics captured from the app log.
It also writes `summary.txt` and `metrics.json` under its temp work root so baseline metric snapshots can be compared across terminal-window parity changes.

For repeatable profiling of the first-party iOS bridge and ownership transfer path:

```bash
apps/macos/Tests/e2e.sh device-api profile
```

That profiler runs against an isolated `SPACES_DB_PATH`, pairs a first-party iOS-shaped installation, attaches a local-window owner plus remote client, measures time-to-owner-render, ownership transfer to iOS, ownership transfer back to the macOS owner, and the streamed visibility latency for both iOS-side and macOS-side input.

`apps/ios/SpacesMobile.xcodeproj` is generated by XcodeGen from `apps/ios/project.yml` and committed, and it lists source files explicitly. After adding or removing a file under `apps/ios/Sources`, `apps/ios/Tests`, or `apps/ios/UITests`, run `xcodegen generate` in `apps/ios` and commit the regenerated `project.pbxproj`, or the iOS build fails on the missing symbol.

For manual simulator verification of the iOS client:

```bash
export SPACES_DB_PATH="$TMPDIR/spaces-ios-demo/spaces.db"
mkdir -p "$(dirname "$SPACES_DB_PATH")"
pkill -x SpacesApp 2>/dev/null || true
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/SpacesApp
mkdir -p "$TMPDIR/spaces-ios-demo/workspace"
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/spacese2e register-project --project-dir "$TMPDIR/spaces-ios-demo/workspace" >/dev/null
(cd "$TMPDIR/spaces-ios-demo/workspace" && env SPACES_DB_PATH="$SPACES_DB_PATH" "$(cd apps/macos/.build/debug && pwd)/spaces" \
  terminal create --command cat --title ios-demo)
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/spacese2e mobile-status
xcodebuild -project apps/ios/SpacesMobile.xcodeproj -scheme SpacesMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

On first launch, the iOS client opens its Devices sheet. Open Devices in the Mac sidebar or run `spaces device pair`, then scan the QR code. The mobile demo lane opens one daemon pairing window per simulator and seeds both the iPad and iPhone simulator settings automatically. The harness stores Mac client metadata in an isolated SQLite file by exporting `SPACES_CLIENT_DB_PATH` and stores harness-only Mac client secrets under `SPACES_CLIENT_SECRET_DIR`; these overrides are for E2E and demo profiles so test pairings do not mix with the user client database or client secret files. Remote mobile scenarios pair the Mac client and iOS simulators with the remote daemon over SSH-backed pairing windows before launching the apps. The demo keeps a local SSH forward to the remote daemon Device API and pairs and seeds every demo client through that forwarded endpoint, so the demo works from networks where the remote daemon port is not directly reachable. After pairing, the iOS client stores the issued credential and pinned daemon fingerprint and reconnects automatically on later launches. The client lists workspaces and live terminal sessions from the selected daemon, auto-attempts takeover when a session detail is opened, renders service-published Ghostty render frames only after ownership is acquired, and shows takeover or status UI while another client still owns the session.
For the iOS simulator, a seeded pairing link with `127.0.0.1` works because the daemon Device API binds all IPv4 interfaces by default. A real device scans the Mac QR code from the Devices panel. The iOS terminal detail path renders the owner-bootstrap Ghostty render frame through the same terminal-grid compatibility data as macOS, so the simulator should show a terminal-like view after takeover rather than a plain-text fallback.

The demo's seeded projects also exercise iOS browser sessions: each workspace carries `docs` and `admin` browser sessions templated on `http://localhost:$SPACES_APP_PORT/...`, which resolve against the workspace's assigned `app` service port and serve real pages once the seeded `frontend` process runs. From a paired simulator or device, tap Run on the `frontend` process row, then tap the `docs` or `admin` browser-session row — the page loads through the Device API service tunnel in the in-app web view. Tapping the row while `frontend` is stopped shows the styled service-not-running page.

For manual real-device verification of the iOS client:

1. Connect the iPhone or iPad to the Mac, unlock it, trust the Mac if prompted, and enable Developer Mode on the device if iOS asks.
2. Create a local `.env` from the tracked sample and set `SPACES_IOS_DEVICE_UDID` to the physical-device UDID printed by `xcrun xctrace list devices`. The `.env` file is ignored by git.

```bash
cp .env.sample .env
xcrun xctrace list devices
$EDITOR .env
```

3. Run the device installer. It builds `SpacesMobile`, installs it on the configured device, and attempts to launch it; if the device is locked, unlock it and tap SpacesMobile or rerun the script. The script launches with `SPACES_MOBILE_PAYWALL_BYPASS=1` so the Debug build skips the subscription gate; launching the app from the home screen instead shows the real gate, which cannot load a product until the subscription exists in App Store Connect (local StoreKit configuration only applies to Xcode-run sessions). To exercise the paywall UI with the fake product, run the app from Xcode.

```bash
scripts/install-ios-device.sh
```

4. If Xcode reports that `dev.usespaces.spacesmobile` cannot be signed by the selected team, stop there and widen the first-party bundle policy before changing the bundle identifier. The Device API accepts only that bundle identifier for pairing and reconnect. Set `SPACES_IOS_DEVELOPMENT_TEAM` in `.env` when the command-line build should override the project signing team.
5. Keep the Mac app and Device API on the same `SPACES_DB_PATH`; the daemon Device API binds all IPv4 interfaces on port `47847` by default.

```bash
export SPACES_DB_PATH="$TMPDIR/spaces-ios-demo/spaces.db"
mkdir -p "$(dirname "$SPACES_DB_PATH")"
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/SpacesApp
mkdir -p "$TMPDIR/spaces-ios-demo/workspace"
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/spacese2e register-project --project-dir "$TMPDIR/spaces-ios-demo/workspace" >/dev/null
(cd "$TMPDIR/spaces-ios-demo/workspace" && env SPACES_DB_PATH="$SPACES_DB_PATH" "$(cd apps/macos/.build/debug && pwd)/spaces" \
  terminal create --command cat --title ios-demo)
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/spacese2e mobile-status
```

6. On the Mac, allow the incoming-network prompt if macOS shows one. In the Mac app, open Devices, choose Pair iPhone or iPad for the target daemon, and scan the QR code from the iPhone or iPad.
7. The first connection attempt should trigger the iOS local-network permission prompt; accept it so the app can reach the daemon Device API.

For a disposable one-command demo stack that launches the macOS app, uses the daemon-hosted Device API, pairs both the iPad and iPhone simulators, and opens the mobile app on each:

```bash
apps/macos/Tests/e2e.sh mobile-demo
```

The launcher expects the local Ghostty artifacts under `apps/macos/.local/ghosttykit/` and remote E2E SSH settings in `.env`. The runner builds the repo-local macOS debug products, the demo builds a fresh simulator `SpacesMobile.app` into a DerivedData directory under the demo root, and that same app bundle is installed on both the iPad and iPhone simulators. Demo runs use the current user's `HOME` and `XDG_CONFIG_HOME` so Ghostty themes and user settings match normal local debugging. By default, the demo uses isolated Spaces profile mode, which keeps the database and runtime under the demo root without moving user-level settings into a temporary home. Use `SPACES_MOBILE_DEMO_PROFILE_MODE=user` when the demo should attach to the repo-local Spaces profile instead. The E2E wrapper uses an ephemeral local Device API port unless `SPACES_MOBILE_DEMO_PORT` is set. The launcher stops the current-profile app owner, current-profile terminal service, and stale repo-local listeners on the selected Device API port before launch. It provisions live Harbor and Lantern workspace terminal sessions, waits for their owner attachments, builds or reuses the repo-local Linux E2E artifact for the configured remote, installs it on the remote daemon account, pairs the simulators with the local daemon and configured remote daemon, then reads the daemon Device API details through `spacese2e mobile-status`. It prints the demo root, profile mode, PIDs, logs, screenshots, project directories, terminal session IDs, the iOS app path, iOS build paths, remote device details, and the simulator app stdout or stderr log paths as JSON, keeps the stack alive until `Ctrl+C`, and then tears the demo down cleanly.

`apps/macos/Tests/e2e.sh mobile-demo --local` brings the same stack up with only the local Mac daemon paired: it skips building or installing the Linux E2E artifact, skips remote daemon pairing and the remote demo project, and needs no remote SSH settings in `.env`. That makes it the quick lane for exercising iOS-only changes.

The same demo root also contains `mobile-terminal-performance.jsonl`, and the printed JSON includes its `performanceLogPath`. The mobile E2E lane consumes that file directly when it asserts one bootstrap epoch, first render timing, input-ready timing, and scrollback behavior.

Useful overrides:
- `SPACES_MOBILE_DEMO_KEEP_ROOT=1` keeps the demo root after shutdown for log inspection.
- `SPACES_MOBILE_DEMO_PROFILE_MODE=isolated|user` selects the Spaces profile mode; demo and E2E runs default to isolated database/runtime paths.
- `SPACES_MOBILE_DEMO_ROOT_PARENT=...` changes the parent directory for demo roots; the default is `~/.spaces-dev/mobile-demo`.
- `SPACES_MOBILE_DEMO_BUILD_MACOS=0` skips the scripted macOS debug build when the existing repo-local binaries should be used.
- `SPACES_MOBILE_DEMO_IPAD_NAME=...` and `SPACES_MOBILE_DEMO_IPHONE_NAME=...` target different simulator names when the defaults are unavailable.
- `SPACES_MOBILE_DEMO_APP_PATH=...` skips the scripted `xcodebuild` and installs an explicit `SpacesMobile.app` bundle.
- `SPACES_MOBILE_DEMO_PORT=...` sets the daemon Device API port for the demo profile; the E2E wrapper supplies `0` by default so the daemon chooses an available port.
- `SPACES_MOBILE_E2E_DEVICE_KEY=iphone|ipad` and `SPACES_MOBILE_E2E_DEVICE_NAME=...` select the simulator used by the mobile E2E lane; the default E2E target is `iPhone 17 Pro`.

For staging App Store screenshots against a running mobile-demo stack, `SpacesMobileScreenshotUITests` navigates the paired app to a chosen screen and holds it idle so a host process can capture it with `xcrun simctl io <udid> screenshot`; the test captures nothing itself. Build the UI test bundle once with `build-for-testing`, then run `testScreenshotStaging` with `test-without-building` once per screenshot, changing only the env vars and (when capturing both simulators) the destination UDID:

```bash
xcodebuild \
  -project apps/ios/SpacesMobile.xcodeproj \
  -scheme SpacesMobile \
  -destination "platform=iOS Simulator,id=$IPHONE_UDID" \
  -derivedDataPath apps/macos/.build/ios-derived-data \
  -only-testing:SpacesMobileUITests/SpacesMobileScreenshotUITests \
  build-for-testing

TEST_RUNNER_SPACES_MOBILE_UI_TEST_CONFIG_PATH="$UI_TEST_CONFIG" \
TEST_RUNNER_SPACES_MOBILE_SCREENSHOT_TAB=agents \
TEST_RUNNER_SPACES_MOBILE_SCREENSHOT_HOLD_SECONDS=45 \
xcodebuild \
  -project apps/ios/SpacesMobile.xcodeproj \
  -scheme SpacesMobile \
  -destination "platform=iOS Simulator,id=$IPHONE_UDID" \
  -derivedDataPath apps/macos/.build/ios-derived-data \
  -only-testing:SpacesMobileUITests/SpacesMobileScreenshotUITests/testScreenshotStaging \
  test-without-building &
sleep 33 && xcrun simctl io "$IPHONE_UDID" screenshot /tmp/agents-tab.png
wait
```

The test reads the same `SPACES_MOBILE_UI_TEST_CONFIG_PATH` config file (and default path) as `SpacesMobileUITests`, but only needs its `host`, `port`, `authToken`, `certificateFingerprint`, and `installationID` fields; build `$UI_TEST_CONFIG` from the mobile-demo stack's printed `deviceAPIHost`/`deviceAPIPort` plus the matching device entry (`ipad` or `iphone`) in `<demo root>/pairing.json`. Each screenshot env var must carry the `TEST_RUNNER_` prefix: `xcodebuild` forwards a prefixed variable to the in-simulator test runner with the prefix stripped, and a bare variable does not reach it. Connect a hardware keyboard for the simulator (`defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool true`) so terminal screens capture without the software keyboard covering the lower half.

`SPACES_MOBILE_SCREENSHOT_TAB` selects `alerts`, `spaces`, `agents`, or `settings`. `SPACES_MOBILE_SCREENSHOT_OPEN_ROW`, honored only with `SPACES_MOBILE_SCREENSHOT_TAB=spaces`, taps the first Spaces row whose visible title contains the given text, opening its terminal detail. `SPACES_MOBILE_SCREENSHOT_PAYWALL=1` launches the app without the paywall bypass so `PaywallView` renders — for the App Store Connect subscription-review screenshot — instead of navigating tabs. In the simulator the paywall's price line stays on its loading state because StoreKit has no product catalog without App Store Connect (the scheme's Run-action StoreKit configuration is not applied to a `test-without-building` UI-test launch); the real price and trial length render on TestFlight and production builds, where StoreKit serves the live product, so capture the final subscription-review screenshot from a real build.

`SPACES_MOBILE_SCREENSHOT_DEMO=1` stages the same screenshots from Demo Mode instead of a paired daemon: it launches with the paywall bypass, resets to a clean not-paired state through the argument domain, enables Demo Mode, then honors the same `SPACES_MOBILE_SCREENSHOT_TAB`/`OPEN_ROW`/`HOLD_SECONDS` variables. No mobile-demo stack, config file, or `.env` is needed, so the App Store screenshot set can be produced on a plain simulator. The daemon-backed lane above is unchanged.

## Demo Mode recording + App Review

The iOS app ships an in-app Demo Mode that tours the whole app from a bundled sample recording with no daemon, network, or account (design in [`docs/implementation.md`](implementation.md#ios-demo-mode); UX in [`docs/spec.md`](spec.md)). It is what the App Store reviewer uses after a free sandbox purchase, and the review-notes template lives in [`docs/app-review-notes.md`](app-review-notes.md).

Re-record the bundle when the recorded content or its encoding changes — the fixture content changes (`apps/macos/Tests/fixtures/e2e_demo`), the render-update wire format changes, or the iOS viewer grids change (font metrics or supported device classes). Regenerate with:

```bash
apps/macos/Tests/record_ios_demo_recording.sh
```

The script builds the debug products, seeds the storytelling fixture into an isolated profile, stages the three workspace states, records each session at the iOS-native grids, enforces the 10 MB bundle budget, and writes `apps/ios/Resources/DemoRecording/`. It is idempotent (fresh temp profile per run) and deterministic up to semantically identical decoded output, not byte-identical. Commit the regenerated bundle.

The pre-submission verification is a single UI test that proves the entire feature end to end with no daemon running. Run it on a booted simulator before every submission:

```bash
xcodebuild -project apps/ios/SpacesMobile.xcodeproj -scheme SpacesMobile \
  -only-testing:SpacesMobileUITests/SpacesMobileDemoModeUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath apps/macos/.build/ios-derived-data test
```

It launches with only `SPACES_MOBILE_PAYWALL_BYPASS=1` and a render-dump path — no host, seed, or daemon env — enters Demo Mode from the empty state, and asserts the sample workspaces, alerts, agents, the read-only terminal transcript and its notice, and that turning Demo Mode off returns to the not-paired empty state. It shadows the persistence keys through the argument domain so a shared simulator's prior state cannot make it flaky. This test is not part of `scripts/verify.sh`; it is the manual submission gate.

Produce the App Store screenshots from Demo Mode with the same `testScreenshotStaging` invocation documented above, adding `TEST_RUNNER_SPACES_MOBILE_SCREENSHOT_DEMO=1` (no mobile-demo stack or config file needed), for example:

```bash
IPHONE_UDID=<booted-udid>
xcodebuild -project apps/ios/SpacesMobile.xcodeproj -scheme SpacesMobile \
  -destination "platform=iOS Simulator,id=$IPHONE_UDID" \
  -derivedDataPath apps/macos/.build/ios-derived-data \
  -only-testing:SpacesMobileUITests/SpacesMobileScreenshotUITests build-for-testing

TEST_RUNNER_SPACES_MOBILE_SCREENSHOT_DEMO=1 \
TEST_RUNNER_SPACES_MOBILE_SCREENSHOT_TAB=agents \
TEST_RUNNER_SPACES_MOBILE_SCREENSHOT_HOLD_SECONDS=45 \
xcodebuild -project apps/ios/SpacesMobile.xcodeproj -scheme SpacesMobile \
  -destination "platform=iOS Simulator,id=$IPHONE_UDID" \
  -derivedDataPath apps/macos/.build/ios-derived-data \
  -only-testing:SpacesMobileUITests/SpacesMobileScreenshotUITests/testScreenshotStaging \
  test-without-building &
sleep 33 && xcrun simctl io "$IPHONE_UDID" screenshot /tmp/agents-tab.png
wait
```

For targeted mobile E2E runs, use `--scenario`:

```bash
apps/macos/Tests/e2e.sh mobile --scenario takeover
apps/macos/Tests/e2e.sh mobile --scenario codex
apps/macos/Tests/e2e.sh mobile --scenario codex-resume-reopen
apps/macos/Tests/e2e.sh mobile --scenario roundtrip
apps/macos/Tests/e2e.sh mobile --scenario scrollback
apps/macos/Tests/e2e.sh mobile --scenario mouse-reporting-scroll
apps/macos/Tests/e2e.sh mobile --scenario two-session
apps/macos/Tests/e2e.sh mobile --scenario ctrl-c-final-frame
apps/macos/Tests/e2e.sh mobile --scenario ctrl-c-final-frame-codex-survivor
apps/macos/Tests/e2e.sh mobile --scenario ownership-guard
```

`codex` starts real Codex in a fresh Mac-owned terminal session and verifies iPhone takeover against the already-running simulator app. Codex scenarios build a generated Codex home inside the demo root by copying the current user's config, linking signed-in auth files, and marking the demo project trusted so the test exercises the TUI instead of the directory-trust prompt. If Codex shows its startup update prompt, the harness selects `Skip` and continues waiting for the TUI. `codex-resume-reopen` runs `codex resume 019e380a-9def-7852-9834-74c67b2da894`, takes over on iPhone, returns to the terminal list, and repeatedly reopens the same session. `roundtrip` drives the Mac/iPhone/Mac/iPhone/Mac ownership path with rendered-content assertions at each handoff. `scrollback` fills the Mac-owned terminal with long output, transfers ownership to iPhone, scrolls away from bottom, runs an owner command while still scrolled up, and checks the owner epoch and prompt rendering. `mouse-reporting-scroll` runs a deterministic SGR mouse-reporting terminal process and verifies that a real Mac wheel event or iPhone simulator swipe reaches it with valid terminal coordinates. `two-session` takes over two fresh terminal sessions through list navigation. `ctrl-c-final-frame` creates `interrupt-target` and `survivor-peer` process-style sessions, sends `ctrl+c` to `interrupt-target` from the iOS owner path, checks the persisted final Ghostty frame on iOS and Mac, and verifies the `survivor-peer` session remains running. `ctrl-c-final-frame-codex-survivor` uses the same interrupt path with a real Codex TUI as the survivor session. `ownership-guard` exercises the Device API ownership rules without UI automation.

Useful overrides:
- `SPACES_MOBILE_CODEX_COMMAND='codex resume <thread-id>'` replaces the default `codex` startup command for the `codex` scenario.
- `SPACES_MOBILE_CODEX_RESUME_THREAD_ID=<thread-id>` changes the thread used by `codex-resume-reopen`.
- `SPACES_MOBILE_CODEX_HOME=<path>` changes the source Codex home used by Codex scenarios; by default they use the current user's `CODEX_HOME` or `~/.codex`. The harness creates a demo-local Codex home from that source so signed-in Codex runs the real TUI without mutating the user's config.
- `SPACES_MOBILE_GHOSTTY_XDG_CONFIG_HOME=<path>` changes the source Ghostty XDG config root used by the mobile E2E harness; by default it uses the current user's `XDG_CONFIG_HOME` or `~/.config`.

When debugging mobile owner render dumps, keep terminal UI rendering frame-based. `GhosttyRemoteTerminalView` must not render from raw output bytes, must not call local session export APIs to reconstruct another owner, mobile owner bootstrap must use the service-published live Ghostty render frame, and macOS owner attach or takeover must use the same service-published frame policy. Do not use VT replay, snapshot-to-VT encoding, raw output, or `output.log` as a terminal-rendering fallback. Use the bootstrap frame, screenshots, event logs, and rendered-content dumps for E2E assertions.

For sustained throughput, repaint-heavy output, tail latency, and scrollback completeness on the built-in terminal path:

```bash
apps/macos/Tests/e2e.sh terminal --scenario stress
```

That profiler runs four isolated scenarios against the embedded Ghostty backend:
- `lines`: high-volume append-only output
- `repaint`: full-screen ANSI clears and redraws
- `mixed`: status repaints plus ordered line emission
- `codex_churn`: long scrollback history plus Codex-style prompt, transcript, spinner, footer rewrite, cursor-move, and redraw churn

`codex_churn` is the primary large-churn regression scenario for the built-in terminal path. Each scenario verifies ordered `SEQ` markers in `output.log`, checks the final frame and final `tail` view, records repeated `spaces terminal tail` wall times, samples output-log growth during the run, and summarizes terminal metrics such as:
- `terminal_output_write`
- `terminal_surface_refresh`
- `terminal_tail_read`

The stress summary prints per-scenario `tail_min`, `tail_median`, `tail_avg`, `tail_p95`, and `tail_max` values so one slow sample does not hide the typical case.
It also prints output-growth summaries from the sampled `output.log` sizes so redraw-heavy regressions show whether tail latency is drifting while the transcript is still growing.
It also records CLI-side tail metrics for each scenario:
- `terminal_tail_read`
- `terminal_tail_command`

Those CLI metrics make it easier to distinguish the internal tail implementation cost from the full `spaces terminal tail` wall time.

For longer-running stability sampling of the same built-in terminal path:

```bash
apps/macos/Tests/e2e.sh terminal --scenario soak --duration-seconds 300
```

That soak harness supports `SOAK_MODE=repaint`, `SOAK_MODE=mixed`, and `SOAK_MODE=codex_churn` with `SOAK_MODE=codex` kept as an alias. The Codex-style mode adds a large initial scrollback history before the steady redraw workload so late-phase transcript pressure looks closer to real long-running Codex sessions.
The soak summary samples `SpacesApp` RSS, CPU, output growth, and `terminal tail` latency at a fixed interval, reports early-vs-late tail drift, verifies that the emitted sequence numbers and final frame stayed complete, and confirms that the final `spaces terminal tail` output still shows the terminal footer and expected last frame after the long run.

For repeatable profiling of the app-triggered built-in workspace-terminal open path:

```bash
apps/macos/Tests/e2e.sh terminal --scenario workspace-terminal-open --samples 3
```

That profiler seeds an isolated fixture workspace, triggers the app-side workspace-terminal open route through the manual E2E IPC helper, and summarizes:
- `workspace_terminal_open_wall`
- `workspace_terminal_open_ui`
- `terminal_session_wait_ready`
- `terminal_window_summon`

For real-system verification of live terminal edit and find shortcuts:

```bash
apps/macos/Tests/e2e.sh terminal --scenario edit-shortcuts
```

That scenario runs the debug app against an isolated `SPACES_DB_PATH`, opens a `cat` session, verifies `Cmd+V` through `spaces terminal tail`, verifies mouse selection plus `Cmd+C` through `pbpaste`, and verifies `Cmd+F`, `Cmd+G`, `Cmd+Shift+G`, and `Esc` through the terminal-window debug dump. It requires the same Accessibility permissions as the other desktop-control E2E scenarios.

For repeatable profiling of the Spaces window hotkey dismiss/summon cycle:

```bash
apps/macos/Tests/e2e.sh terminal --scenario spaces-terminal-hotkeys --samples 3
```

That profiler runs against an isolated `SPACES_DB_PATH`, enables `DEBUG=1`, focuses a tracked built-in process terminal pane, then repeatedly drives `Cmd+Opt+=` through a two-phase cycle — dismiss (the window is up and the app active, so the hotkey hides both) then summon (the app is in the background, so the hotkey reveals the window and refreshes the selection) — while summarizing:
- `dismiss_toggle_wall`
- `summon_toggle_wall`
- `toggle_window_dismiss`
- `toggle_window_summon`
- `toggle_window_reveal_target`
- `toggle_window_selection_refresh`

For repeatable profiling of the built-in `Spaces terminal -> command palette -> tracked process terminal` hotkey loop:

```bash
apps/macos/Tests/e2e.sh terminal --scenario spaces-terminal-palette --samples 3
```

That profiler runs against an isolated `SPACES_DB_PATH`, enables `DEBUG=1`, and verifies that selecting a second tracked process from the command palette while the first process owns focus leaves the selected process focused. It then repeatedly opens the command palette with `Cmd+Opt+-`, dismisses it, and refocuses the tracked terminal through the normal workspace-process path while summarizing:
- `terminal_to_palette_toggle_wall`
- `toggle_palette`
- `toggle_palette_terminal_workspace_lookup`
- `toggle_palette_context_workspace`
- `toggle_palette_reveal_target`
- `toggle_palette_apply_filter`

For workspace-process profiling, use:

```bash
apps/macos/Tests/e2e.sh terminal --scenario workspace-process-terminal
```

That profiler waits for the built-in session summon metric instead of sleeping a fixed second after refocus, so the reported close or reopen timings track the actual app-side window path more closely.

For Device API control-lane profiling — what a keystroke's control round trip costs while several sessions stream — use:

```bash
SAMPLES=120 PRODUCERS=5 apps/macos/Tests/profile_device_api_control_lanes.sh
```

It runs its own throwaway profile and daemon (never the installed one), streams `PRODUCERS` bursty agent-shaped sessions at roughly 100 KB/s each, resyncs every one of them with `.state` from its own connection while a sidebar-shaped `.overview` poll runs, then reports p50/p95/max for the typed control round trip, for `.overview`, and for the DEBUG-gated `device_api_control_lane_wait` read out of the profile's `perf.log`. The corroboration `.ping` is not measured: every sample would have to dial through the CLI, timing a process launch that dwarfs the round trip, and a unit test already pins that a ping is answered clear of the shared queue. The daemon runs with `DEBUG=1`, which costs it real work, so absolute numbers are only comparable against another run of this script. Nothing is published unless the run is comparable: the perf log must have armed, every producer must have streamed and stayed alive across the measured window, and the `.overview` poll must have run to the end unrejected — otherwise the script prints what went wrong and exits nonzero with no summary. A daemon that armed its log but emits no `device_api_control_lane_wait` row anywhere is recognized as a pre-lane build, which is what makes the before half of a before/after comparison runnable: it publishes the externally measured distributions with the lane-wait fields omitted and `lane_wait_metric: "absent"` in their place, while a daemon that does emit the metric is still refused if the window carries none. Lane waits and revisions are read from the window that starts at the first counted sample, so warm-up and startup traffic stay out of the distributions.

## Pre-commit Hook

Git commits can use the repo hook in `.githooks/pre-commit`, which runs the canonical local verification path.

Enable the repo-managed hooks once per clone:

```bash
git config core.hooksPath .githooks
```

Verify the setting:

```bash
git config --get core.hooksPath
```

Expected output:

```text
.githooks
```

The pre-commit hook runs `scripts/verify.sh`, which formats staged macOS Swift source and test files, lints, builds, then runs the SwiftPM coverage tests and the iOS unit tests together.

Pull requests are checked in GitHub Actions with [`.github/workflows/pr-checks.yml`](../.github/workflows/pr-checks.yml), which runs the same Swift verification flow, the static website build, and Linux artifact builds on native x86_64 and arm64 runners.

## Manual E2E

Run the real-system GUI/CLI suite from the repository root with:

```bash
apps/macos/Tests/e2e.sh app
```

Before the suite launches its isolated app instance, it waits for desktop-global control. A timeout from that wait is an environment-contention result and should be retried without killing unrelated running Spaces instances.

The macOS E2E suite seeds the shared Harbor, Lantern, and Atlas fixture repositories and runs the app-level launch, focus, cycling, workspace, and agent-status assertions against the current profile's same-machine daemon.

With `SPACES_E2E_RUN_REMOTE=1`, the suite also prepares a paired remote Linux daemon from the repo-root `.env`, seeds the Mac client with that device, starts a remote named service, focuses its browser session, and verifies the service through the Mac Caddy router backed by the SSH local forward. The remote lane reads the harness profile's Mac client identity through `spacese2e mac-client-installation-id` so pairing uses the same identity as the app.

For a focused app smoke pass:

```bash
apps/macos/Tests/e2e.sh app --scenario smoke
```

For the combined smoke lane:

```bash
apps/macos/Tests/e2e.sh all
```

This suite is manual by design. It drives the real app, `spaces`, Chrome, and the built-in Spaces terminal in an interactive macOS session instead of XCTest.

Primary coverage:
- adding and deleting a workspace
- overriding workspace settings after creation
- launch, stop, restart, and dead-process recovery
- built-in Spaces terminal coverage
- extra user-added Chrome and terminal tabs
- workspace-detail numbered focus shortcuts
- forward/back workspace window cycling
- multi-workspace focus and cycling isolation
- remote browser-session routing through SSH local forwarding and the Mac Caddy router

The suite emits performance metrics in milliseconds for the main window-focus and cycle paths, using the app's debug timing logs for the same shortcut and cycling flows covered by the standalone focus-profiling workflow. The final summary prints both the pass/fail case list and the collected timing samples with count, p50, p95, max, and raw samples, so this suite is the primary path for focus profiling during development. The `app window-cycle` scenario runs the window-cycle profile path; set `REAL_SYSTEM_PROFILE_WARMUPS=5 REAL_SYSTEM_PROFILE_REPETITIONS=30` to collect steady-state samples after warmup without changing the normal full-suite pass. For faster app-side cycle latency iteration, `app window-cycle-small` runs only the primary workspace setup and repeated cycle loop; use `--samples N` for the repetition count, or set `REAL_SYSTEM_PROFILE_WARMUPS=0` with a small sample count for a quick local probe.

Latency work uses a measured baseline before implementation changes. Run the same app E2E/profile scenario with the same warmup and repetition counts before and after a candidate optimization, then compare the generated artifacts. Optimize only phases whose p95 is at least `15 ms` or at least `20%` of the total p95 for that flow. The profile output should cover browser-session focus, existing terminal-pane focus, terminal pane open-from-focus, browser-to-pane cycling, pane-to-browser cycling, and pane-to-pane cycling.

`DEBUG=1` app perf lines split focus work into named phases: shortcut dispatch, target resolution, client database lookup/write, Chrome AppleScript, existing-pane focus, pane open, ownership request, focus observation, route time, and total elapsed time. Use those phase fields to identify the bottleneck before changing the implementation.

Repeated real-system profiling also covers:
- main window visibility toggles from inactive and active app states
- command palette toggles from inactive and active app states
- built-in `Spaces terminal -> main window -> tracked process terminal` focus loops
- built-in `Spaces terminal -> command palette -> tracked process terminal` focus loops

When the suite finishes with recorded metrics, it appends aggregated metric history to `apps/macos/.artifacts/real-system-profiles/metrics-history.csv` and regenerates `apps/macos/.artifacts/real-system-profiles/report.html` with `best`, `previous`, and `latest` comparisons for each tracked metric. Metric rows include average, p50, p95, min, max, raw samples, and latest-vs-previous p50/p95/max deltas in milliseconds and percent. Metric names use `start.action.end`, such as `browser_untracked_tab.cli_window_focus.browser_tracked_tab`, and the start and end tokens refer to concrete visible surfaces rather than app-level state. Scenario context like workspace scope is stored alongside each row. Dirty worktrees are recorded alongside clean runs by pairing the base `HEAD` commit with a worktree fingerprint, so the report can distinguish two different uncommitted snapshots on the same branch. The E2E artifact report preserves the profile CSV, HTML report, app profile `perf.log`, and raw `spaces: perf metric=...` lines with request IDs for stage-level joins.

The manual suite depends on a small set of debug-log lines from the app and CLI helpers. Treat these as test contracts when changing debug logging:
- `spaces: perf metric=...`
- `spaces: workspace_detail_ipc selecting ...` / `selected ...`
- `spaces: workspace_run_view workspace=... selected=... agents=... coding_entries=...`

## Website

Run from `apps/web`:

```bash
npm run dev
npm run build
```

`scripts/make-readme-device-art.py` regenerates the README's device-framed product shot (`docs/media/readme-ios.png`) from the screenshots in `apps/web/public/media/`.

## Version Metadata

`apps/macos/AppVersion.plist` is the only place a Spaces version is authored. Every consumer is generated from it by `scripts/sync-app-version.sh`:

```bash
scripts/sync-app-version.sh --short <version> --build <build-number>
```

- `apps/macos/Sources/workspacecore/AppVersion.swift` — the constants the CLI, app menu, and daemon report
- `apps/macos/Sources/SpacesApp/Info.plist` — regenerated wholesale from a template in the script
- `apps/ios/Info.plist` — version keys rewritten in place, leaving its hand-maintained keys alone

Edit none of these by hand. Spaces ships one version across its clients, so the Mac and iPhone apps report the same `CFBundleShortVersionString`; `AppVersionMetadataTests` fails the build on any drift between the source and either bundle.

A client's own version is never compared against a daemon's to decide anything — see the daemon-compatibility notes in [implementation.md](implementation.md).

Because the macOS `Info.plist` is regenerated from a template rather than edited in place, a new key belongs in that template in `scripts/sync-app-version.sh` — a key added only to the generated file is silently dropped on the next sync.

## macOS Release

Publish macOS releases to GitHub Releases with:

```bash
scripts/release-and-deploy.sh <version> [build-number]
```

In CI the same release is cut by pushing a stable version tag, which runs [`.github/workflows/release.yml`](../.github/workflows/release.yml) — a thin caller of the reusable [`release-build.yml`](../.github/workflows/release-build.yml) it shares with the nightly channel described below.

Local release runs the Ubuntu remote daemon artifact builds inside Docker for `linux/amd64` and `linux/arm64`, so Docker must be available before running the script. These Linux artifacts are installed by the published `https://usespaces.dev/install.sh` script, run on the Ubuntu device manually or by the Mac app over SSH during pairing recovery. Remote Macs use the signed DMG rather than a separate daemon artifact.

This workflow:
- syncs the checked-in version metadata used by the CLI, app menu, and bundle plist
- builds universal `arm64` + `x86_64` release binaries for the app, CLI, and `spacesd`
- code-signs the app, CLI, spacesd daemon, and bundled Caddy executable
- builds and smoke-tests Ubuntu 24.04 `x86_64` and `arm64` remote daemon artifacts, including a reinstall leg that pokes the running daemon (`apply-update`) and asserts the exec-in-place handoff preserves the daemon pid and its live session
- signs `spaces-remote-artifacts.json` with the remote artifact Ed25519 key that the Linux installer uses to verify the Linux artifact download
- creates a signed manual-download DMG
- creates a Sparkle-served `Spaces.app` zip archive
- updates `dist/updates/stable/appcast.xml` plus any Sparkle delta files
- optionally notarizes the DMG when `NOTARIZE=1`
- verifies the final DMG signature plus the bundled installer, app, CLI, and spacesd daemon before publish
- publishes the DMG, the Sparkle zip, and `appcast.xml` to GitHub Releases
- publishes `spacesd-ubuntu-24.04-x86_64.tar.gz`, `spacesd-ubuntu-24.04-arm64.tar.gz`, their `.sha256` checksum files, `spaces-remote-artifacts.json`, and `spaces-remote-artifacts.json.sig` to the same GitHub Release
- builds the static site last, since the site's `prebuild` stages the Sparkle feed back out of the release it just published

Important environment variables:
- `CODESIGN_IDENTITY`
- `CODESIGN_CERTIFICATE_P12`
- `CODESIGN_CERTIFICATE_PASSWORD`
- `SPARKLE_PUBLIC_ED_KEY`
- `SPARKLE_PRIVATE_ED_KEY`
- `REMOTE_ARTIFACT_PUBLIC_ED25519_KEY`
- `REMOTE_ARTIFACT_PRIVATE_ED25519_KEY`
- `SPARKLE_FEED_URL`
- `SPARKLE_DOWNLOAD_URL_PREFIX`
- `NOTARIZE`
- `APPLE_ID`
- `TEAM_ID`
- `APP_PASSWORD`
- `GH_TOKEN`

For GitHub Actions releases, `CODESIGN_CERTIFICATE_P12` must be the base64-encoded Developer ID Application `.p12` bundle that matches `CODESIGN_IDENTITY`, and `CODESIGN_CERTIFICATE_PASSWORD` must be the password used when exporting that `.p12`.

Stable Sparkle update hosting lives under `https://usespaces.dev/releases/` on the static Firebase site, which Next.js exports as real static files before Firebase deploy. A Firebase Hosting deploy replaces the whole site, so the GitHub release is the source of truth for what that directory contains: `scripts/stage-web-releases.sh` runs from the `apps/web` `prebuild` and downloads `appcast.xml` and the Sparkle zip it names from `releases/latest/download` on every build. Any website build — merge deploy, PR preview, release, local — therefore republishes a complete feed instead of blanking it, and a release that failed to publish those two assets fails the next site build loudly. The Linux installer is published the same way, copied to `https://usespaces.dev/install.sh` by the same `prebuild` rather than as a GitHub release asset. The app bundle carries `spaces`, `spacesd`, and Caddy in `Contents/Resources`; the DMG installer links `/usr/local/bin` and `~/.spaces/bin` helpers to those bundled binaries so installed CLI commands, launchd, and remote Mac pairing use the updated app bundle after Sparkle updates. Linux artifacts link `~/.local/bin/spaces` to the managed `~/.spaces/bin/spaces` helper so user shells can run `spaces` without a system-wide install.

## Nightly Channel

[`.github/workflows/nightly.yml`](../.github/workflows/nightly.yml) cuts a nightly build from the tip of `main` at 09:00 UTC and on `workflow_dispatch`. It shares its entire body with the stable release: both are thin callers of the reusable [`release-build.yml`](../.github/workflows/release-build.yml), which takes `channel`, `version`, `build`, and `release-tag` and resolves the four channel knobs — Sparkle feed URL, appcast download prefix, the host the post-deploy check curls, and the Firebase Hosting entry point — from `channel` alone.

A nightly version is the newest stable tag plus a UTC `YYYYMMDDHHMM` timestamp, `0.5.1.202607250900`, and that same timestamp is its `CFBundleVersion`. Four dotted numeric components are required rather than a `-nightly` suffix: `SpacesWireProtocol.isVersion(_:olderThan:)` maps non-numeric components to `0`, so a suffixed version would sort below the release it was built from and suppress the staged-update hint. Minute precision keeps a second dispatch on the same day distinct in both values — Sparkle compares the build number, while the daemon compares marketing versions to notice a staged build, so a shared version would update the app and leave the daemon on the earlier binary. A scheduled run whose `main` tip already has a nightly tag exits before building; a manual dispatch always builds.

Nightly publishes to its own Firebase Hosting site, `spaces-nightly.web.app`, configured by [`deploy/nightly/firebase.json`](../deploy/nightly/firebase.json) and populated by `scripts/stage-nightly-site.sh`. The site serves only `releases/appcast.xml`, the Sparkle zip, a `noindex` landing page, and a `robots.txt` that disallows crawling; it carries no rewrites, so a missing asset returns 404 rather than an HTML page with HTTP 200. Keeping it a separate site is what lets nightly run daily without deploying `apps/web`, whose `main` state carries unreleased website work.

The nightly DMG, Linux daemon artifacts, and signed manifest go to a GitHub prerelease tagged `v<version>`, pinned with `--target` to the commit that was built. Prereleases never claim `releases/latest`, so `install.sh`'s no-version path stays on stable, while the version-pinned form resolves a nightly the same way it resolves any release. The workflow prunes nightly prereleases beyond the newest seven, acting only on prerelease-marked releases whose tags have four numeric components. `release.yml` and `ios-release.yml` exclude those tags from their `v*` triggers, so a nightly never re-enters the stable pipeline or cuts a TestFlight build through the tag path.

Creating the hosting site is a one-time step: `firebase hosting:sites:create spaces-nightly --project spaces-a1814`. The existing `FIREBASE_SERVICE_ACCOUNT_SPACES_A1814` secret covers it, and no other secret or DNS record is involved.

The nightly's `ios` job runs in parallel with the macOS build from the same `plan` job, gated on the same `build-needed` output and independent of it — a failure on one side does not block the other. It calls [`ios-release.yml`](../.github/workflows/ios-release.yml) as a reusable workflow (`workflow_call`) rather than through the tag path, because App Store Connect caps `CFBundleShortVersionString` at three numeric components and the nightly's four-component version would be rejected at upload. It passes the latest stable marketing version (the same one the nightly's own version is built from) and the nightly's `YYYYMMDDHHMM` timestamp as the build number, so TestFlight groups nightly uploads under the stable version train while the timestamp keeps each build unique and ordered.

## iOS Release

[`.github/workflows/ios-release.yml`](../.github/workflows/ios-release.yml) builds the iOS app and uploads it to App Store Connect for TestFlight. Pushing a stable version tag runs both the macOS and iOS release workflows, so the same version ships across every client; both exclude the four-component tags the nightly channel cuts. A `workflow_dispatch` run with a required `version` input cuts a TestFlight-only build from any branch without tagging a public macOS release. The nightly channel calls the workflow directly as `workflow_call` with `version` and `build` inputs, described in the Nightly Channel section above. The build number is `GITHUB_RUN_NUMBER` only when neither trigger supplies a `build` input (tag push and `workflow_dispatch`); `workflow_call` supplies it explicitly. `scripts/sync-app-version.sh --short <version> --build <build>` stamps the shared version metadata while preserving the checked-in Sparkle feed URL and keys.

The workflow obtains `GhosttyKit` the same way as the macOS release, running `apps/macos/scripts/ensure_ghostty_artifacts.sh --publish-missing` so the pinned-submodule `GhosttyKit.xcframework` (including its iOS device and simulator slices) is present, then `xcodebuild archive`/`-exportArchive` with [`apps/ios/ExportOptions.plist`](../apps/ios/ExportOptions.plist) (`method: app-store-connect`, `destination: upload`). The export step itself uploads the build to App Store Connect. The `.xcarchive` is retained as a workflow artifact for debugging. In `apps/ios/project.yml`, the `SpacesMobile` scheme's build targets list `SpacesMobileTests` and `SpacesMobileUITests` with `[test]` rather than `all`, so their `BuildActionEntry` gets `buildForArchiving="NO"`: those targets `@testable import SpacesMobile`, which needs the app built with `-enable-testing`, a flag `xcodebuild archive -configuration Release` does not set. Leaving the test targets on `all` would have `archive` compile them in Release and fail every release build; XcodeGen regenerates the shared scheme from this setting, so hand-editing the generated `.xcscheme` does not stick.

Signing imports two long-lived certificates from secrets into a temporary keychain, the same shape the macOS release uses for its Developer ID certificate. `xcodebuild` still runs with `-allowProvisioningUpdates` and the App Store Connect API key so it can create and refresh *provisioning profiles*, which Apple does not cap, but it finds both signing identities already present and mints no certificate.

Both are needed because the two build phases sign with different identities. The target signs automatically, so `xcodebuild archive` signs the archive for **development** and `-exportArchive` re-signs it for **distribution**. Supplying only the distribution half leaves the archive asking Apple for a development certificate on every run. Forcing the archive onto the distribution identity is not an alternative: with automatic signing, a manually specified `CODE_SIGN_IDENTITY` fails during provisioning-input gathering with `automatically signed for development, but a conflicting code signing identity Apple Distribution has been manually specified`.

The certificates are stored rather than cloud-managed because a certificate is bound to the private key that generated its CSR, and a runner's keychain dies with the runner. Cloud-managed signing therefore issued a fresh certificate per run and left the previous one behind — unusable, since its key no longer existed anywhere, but still counted against Apple's per-team certificate cap. Nine releases exhausted the cap, and the archive step then failed with `Your account has reached the maximum number of certificates` on tags whose commits had every check green.

The workflow reads seven secrets:
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_API_KEY_P8` (raw `.p8` key contents, written to `$RUNNER_TEMP` with `600` permissions for the build only)
- `IOS_CODESIGN_CERTIFICATE_P12` (base64-encoded Apple Distribution `.p12`, certificate *and* private key)
- `IOS_CODESIGN_CERTIFICATE_PASSWORD` (the password used when exporting that `.p12`)
- `IOS_CODESIGN_DEV_CERTIFICATE_P12` (base64-encoded Apple Development `.p12`, certificate *and* private key)
- `IOS_CODESIGN_DEV_CERTIFICATE_PASSWORD` (the password used when exporting that `.p12`)

To mint or renew either certificate, create it in [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list) — one **Apple Distribution**, one **Apple Development** — download it, open it in Keychain Access, export the certificate *with* its private key as a `.p12`, and set the matching pair of secrets from `base64 -i <file>` and the export password. Apple issues these with a one-year validity, so renew before expiry. Revoking a superseded certificate after a successful run keeps the cap clear.

Three checks guard the arrangement, because every way it can regress otherwise produces a green release that silently leaks a certificate, and the leak is only discovered when the cap fills and a tagged release fails.

- **Both identities are usable.** `security find-identity -v` lists valid identities only, so a `.p12` exported without its private key, or a certificate past its one-year expiry, fails here with a named error rather than inside `xcodebuild`.
- **Both certificates belong to the signing team.** A maintainer on more than one Apple team can export a perfectly valid certificate from the wrong one, which the check above accepts and Xcode then cannot use. The team is read from the certificate's organizational unit rather than its common name: a distribution certificate's common name ends in the team id, but a development certificate's parenthetical is a per-certificate identifier, so matching the common name would reject the correct certificate and fail every release.
- **The archive actually used an imported certificate.** Apple names a certificate minted through the App Store Connect API `Created via API`, so the archive log naming it as the signing identity means `xcodebuild` asked for a new certificate instead. The import checks cannot catch this — they prove both identities are in the keychain, not that `xcodebuild` chose them — so the archive step fails when that name appears.

The App Store Connect app record for `dev.usespaces.spacesmobile` must already exist before the first upload.

## Website Deploy

Firebase Hosting deploys from [`.github/workflows/firebase-hosting-merge.yml`](../.github/workflows/firebase-hosting-merge.yml). It builds `apps/web` and deploys the static export on pushes to `main` that touch the site or on manual dispatch.

The workflow authenticates with GitHub OIDC through Google Workload Identity Federation, then deploys through the Firebase Hosting REST API. This avoids `firebase-tools` service-account-key assumptions while keeping the deploy keyless.

Required GitHub secrets:
- `FIREBASE_PROJECT_ID`
- `GCP_WORKLOAD_IDENTITY_PROVIDER`
- `GCP_SERVICE_ACCOUNT_EMAIL`
