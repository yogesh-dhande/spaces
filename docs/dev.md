# Spaces Development

Build, test, and release workflows for the Spaces monorepo. For product overview and adoption, see [README.md](../README.md).

## Repo Layout
- `apps/macos`: macOS app, `spaces` CLI, `spacesd` daemon, Swift sources and tests, and the Editor's web bundle (`CodePaneWeb`)
- `apps/ios`: iOS app
- `apps/web`: static marketing site and user-facing docs
- `docs`: product, implementation, design, and development docs
- `scripts`: root wrappers for build, test, coverage, release, and deploy workflows
- `.agents/skills`: agent skills for E2E, QA, release, Ghostty sync, and cleanup workflows

## Documentation Map
- [`README.md`](../README.md): product overview and adoption pitch
- [`AGENTS.md`](../AGENTS.md): how coding agents should write, verify, and document changes
- [`docs/spec.md`](spec.md): product behavior rules (the non-standard, user-visible business logic)
- [`docs/implementation.md`](implementation.md): module boundaries, data model, and implementation rationale
- [`docs/design.md`](design.md): visual system and interaction patterns
- [`apps/macos/CodePaneWeb/README.md`](../apps/macos/CodePaneWeb/README.md): the Editor's web bundle and its bridge protocol
- [`apps/web/app/docs`](../apps/web/app/docs): user-facing product and CLI documentation

## Requirements
- Xcode at the version pinned in `.github/actions/select-xcode/action.yml` (prebuilt Ghostty artifacts are keyed by it; see Ghostty Artifacts)
- Google Chrome, for browser sessions
- Docker, for the Linux daemon build and tests
- Node.js and npm (CI uses Node 22), for `apps/web` and `apps/macos/CodePaneWeb`
- XcodeGen, to regenerate the iOS project

## Build, Lint, Test

Run from the repository root:

```bash
scripts/format.sh
scripts/swiftpm.sh build
scripts/swiftpm.sh test --parallel
scripts/lint.sh
scripts/coverage.sh
scripts/verify.sh
```

- `scripts/format.sh`: tree-wide `swift format` pass over the macOS and iOS source/test trees, using the repo-root `.swift-format`.
- `scripts/format-staged-swift.sh`: formats only staged macOS/iOS Swift files and re-stages them.
- `scripts/lint.sh`: runs `format-staged-swift.sh`, then SwiftLint when `swiftlint` is on `PATH`.
- `scripts/coverage.sh`: builds coverage-instrumented SwiftPM test targets into their own scratch path (`apps/macos/.build/coverage-scratch`, separate from the plain `.build` that holds `spaces`/`spacesd`/`spacese2e`/`SpacesApp`, so neither build invalidates the other's incremental state), then runs tests in parallel. `SPACES_TEST_PARALLEL=0` forces serial; `SPACES_TEST_WORKERS` sets worker count; `SPACES_TEST_MAX_AUTO_WORKERS` caps auto-detected workers. Real child-process signal-delivery tests run in their own serial process because parallel workers can starve spawned shell groups. The mirror-surface suites (`GhosttyMirrorForwardedClickTests`, `GhosttyMirrorGraphemeClusterTests`, `GhosttyMirrorLinkActivationTests`, `GhosttyMirrorSelectionAcrossFramesTests`, `GhosttyMirrorSurfaceMRUTests`, `GhosttyMirrorSurfacePresentationTests`) start a real mirror-owned ghostty app; only one may be live per process, so they run together in their own follow-up process against the same coverage scratch, and are skipped on CI (`GITHUB_ACTIONS`), which cannot host a rendering ghostty surface; local `verify.sh` is their only gate. Coverage also points `XDG_CONFIG_HOME` at an empty build-local directory so Ghostty tests do not load a developer's personal config.
- `scripts/verify.sh`: the canonical local gate. Order: the script regression tests (simulator lifecycle, silence watchdog, Ghostty setup and artifact-key drift, Linux deploy profile validation), a Ghostty artifact sync (`setup_ghostty.sh`, installs artifacts matching the pinned submodule; no-op when the local manifest already matches, mirrors the `ensure_ghostty_artifacts.sh` step CI runs), staged formatting and lint, one plain SwiftPM build (uninstrumented `.build/debug`), release bundle signing, current-profile app/spacesd shutdown, then the SwiftPM coverage run (foreground) and the iOS test lane (background) together. Set `SPACES_VERIFY_KEEP_PROFILE_RUNTIME=1` to skip the shutdown step. The iOS lane builds once and runs `SpacesMobileTests` + `SpacesMobileSmokeUITests` (one smoke class per screen, driven against the bundled Demo Mode recording, so no daemon/network/paired Mac is needed); `SpacesMobileUITests` (drives a live daemon and paired Mac) is skipped here and runs on demand via `apps/macos/Tests/e2e.sh mobile`. The iOS lane boots an available shut-down iPhone simulator (so it doesn't collide with a simulator mobile E2E owns) and uses DerivedData at `apps/macos/.build/ios-derived-data`, reused incrementally; its log is `apps/macos/.build/ios-verify.log`, tailed by `verify.sh` after the lane finishes. Already-built test processes run under a silence watchdog (`SPACES_VERIFY_STALL_SECONDS`, default 600, `0` disables it), and the iOS build-for-testing phase under a longer one (`SPACES_VERIFY_IOS_BUILD_STALL_SECONDS`, default 900); SwiftPM builds and coverage export have no time ceiling. Every run closes with a lane summary (what ran, what did not, and what no `verify.sh` lane covers: desktop/mobile/remote-daemon E2E, and the Linux daemon unit lane and artifact smoke test, which run in CI).
- `scripts/swiftpm.sh` (root wrapper for `apps/macos/scripts/swiftpm.sh`): binds every `test` invocation to a throwaway profile under `apps/macos/.build/test-profile`, so tests never touch the installed or worktree profile; a bare `swift test` outside this wrapper fails loudly instead (profile resolution refuses the installed/dev-profile paths inside a test process). Also holds a fail-fast lock (`.build/swiftpm-exec.lock`) so overlapping build/test/coverage invocations fail fast instead of silently contending on `.build`.
- `apps/macos/scripts/impacted_tests.sh`: runs only the SwiftPM test targets affected by the working tree's changes against `origin/main` (maps changed paths to targets via `swift package describe`, then `scripts/swiftpm.sh test --filter`). A change outside `Sources/`/`Tests/` under `apps/macos` (`Package.swift`, `Package.resolved`, `scripts/`, ...) runs the full suite instead. It only narrows which already-built tests execute (the build step is always full) and does not replace `scripts/verify.sh` as the gate.

The Editor's web bundle (`apps/macos/CodePaneWeb`) is a separate Vite/TypeScript project built with npm (see its `README.md`); `npm run build` emits into `apps/macos/Sources/spacesui/Resources/CodePane/`, which is checked in and bundled as a `.copy` resource of the `spacesui` target. The Swift build/test lanes never invoke node.

## Local Entry Points and Profiles

```bash
apps/macos/.build/debug/SpacesApp
apps/macos/.build/debug/spaces --help
apps/macos/.build/debug/spacese2e --help
apps/macos/.build/debug/spaces project list
apps/macos/.build/debug/spaces workspace create --project <project-id> --branch debug
apps/macos/.build/debug/spaces workspace restart --workspace <workspace-id>
apps/macos/.build/debug/spaces terminal list
apps/macos/.build/debug/spacese2e profile-show
```

Each binary resolves its own worktree-scoped profile from where it sits (`~/.spaces-dev/profiles/spaces/<branch-slug>-<worktree-hash>/`), so no shell binding is used or needed. `spacese2e profile-show` prints the resolved profile's root, database, and runtime paths (a lookup, not a binding; nothing exports these into the shell). `SPACES_DB_PATH` names an ephemeral throwaway profile root only (a scratch run, an E2E harness); resolution refuses it when it points inside `~/.spaces/` or `~/.spaces-dev/profiles/`, since a real profile's identity comes from where the running binary lives. Override `SPACES_RUNTIME_DIR` alongside it only when the runtime files must move with that throwaway profile too.

Use `scripts/dev-build-and-launch.sh [--local]` to build and launch the debug app without touching the installed app's database. It prepares Ghostty artifacts before invoking SwiftPM, stops only the current profile's running app instance before relaunching (its spacesd is stopped only when it owns no sessions, so live sessions survive and the app reattaches), and re-applies a staged newer binary through the exec-in-place handoff if the daemon is older. A directly-run newer `spacese2e` refuses to migrate an older daemon's profile on its own; run `spaces daemon apply-update` first. Without `--local`, and with `.env` configuring `SPACES_E2E_REMOTE_SSH_HOST`, the script also builds/uploads the current-checkout Ubuntu artifact and installs it as a remote *development profile* named after this worktree's local profile (`install.sh --profile <name>`), running as `spacesd@<name>.service` under `~/.spaces-dev/profiles/spaces/<name>/`; the installed `~/.spaces` daemon is left alone, and several worktrees/developers can deploy to the same device at once. It prints the profile root and the Device API port the daemon assigned itself (from that profile's `runtime/terminal/device-api.json`).

A device whose single `spacesd.service` is pinned to a development profile needs that unit stopped once (`systemctl --user stop spacesd` on the device), because the pinned daemon holds the profile-root lock a `spacesd@<name>.service` instance needs. Clear the pin for good by running the installer with no arguments on the device (rewrites the unit to serve the installed profile).

A remote development profile is reachable only if its Device API port is open on the device's network. Only the canonical `47847` is conventionally open; a firewalled device needs ingress for the whole development range `47848`-`47947` (one rule covers every profile). On Google Cloud: `gcloud compute firewall-rules create <name> --network <network> --direction INGRESS --action allow --rules tcp:47848-47947 --target-tags <instance-tag>`.

`spacese2e profile` is the inventory/cleanup surface for these accumulating profiles (it lives in `spacese2e` rather than `spaces` because managing dev profiles is not product behavior):

```bash
apps/macos/.build/debug/spacese2e profile list            # this Mac: profile, recorded Device API port, last touched
apps/macos/.build/debug/spacese2e profile list --remote   # the device, plus daemon state and live session count
apps/macos/.build/debug/spacese2e profile stop --remote <name>
apps/macos/.build/debug/spacese2e profile remove --remote <name>
```

`--remote` resolves the device from the same `.env` remote keys every remote workflow uses (source `scripts/spaces-e2e-env.sh` first). `stop` stops one unit instance and leaves the profile/unit enabled; `remove` refuses a profile whose daemon still holds sessions (or is running but not answering, `stop` first), then disables the instance and deletes the profile root. Both refuse `(installed)`.

### Keeping the Chrome Automation grant across rebuilds

Ad-hoc signed SwiftPM debug builds get a fresh cdhash (the app's TCC identity) on every rebuild, so the macOS Automation grant that lets Spaces control Chrome is lost each rebuild. Set `SPACES_DEV_CODESIGN_IDENTITY` in the gitignored repo-root `.env` to a stable signing identity (an "Apple Development: ..." line from `security find-identity -v -p codesigning`); `dev-build-and-launch.sh` re-signs the built app with it after SwiftPM. If a stale TCC record is already blocking the prompt: `tccutil reset AppleEvents dev.usespaces.spaces`, then click Recheck (or relaunch).

## Troubleshooting

Every path below is relative to a profile's runtime directory: `~/.spaces/runtime/` for the installed profile. For a repo-local development profile, print its runtime directory with `apps/macos/.build/debug/spacese2e profile-show` from that worktree.

| What | Where |
| --- | --- |
| Daemon log | `terminal/service.log` |
| Daemon stdout and stderr under launchd (Mac) | `spacesd.launchd.out.log`, `spacesd.launchd.err.log` |
| A terminal session's output transcript | `terminal/sessions/<session-id>/output.log` |
| A workspace's setup script log | `workspace-setup/<workspace-id>/setup.log` |

Recent output of any session, local or on a paired device, without reading files:

```bash
apps/macos/.build/debug/spaces terminal list [--device <name>]
apps/macos/.build/debug/spaces terminal tail <session-id> [--lines 200] [--device <name>]
```

If Ghostty owner/mirror setup reports `ghostty_session_new_headless failed` or `ghostty_mirror_new failed`, check for stale debug daemons first: `pgrep -af 'SpacesApp|spacesd|spacese2e|xcodebuild|e2e|mobile-demo'`, confirm each pid with `ps eww -p <pid> -o pid,ppid,command`, and kill only processes belonging to the current checkout or a preserved E2E run root; leave other worktree profiles running. `GHOSTTY_LOG=stderr` shows why libghostty refused a session; when it points at the artifacts, `setup_ghostty.sh --build` rebuilds from the pinned submodule.

## Ghostty Artifacts

```bash
apps/macos/scripts/setup_ghostty.sh
```

Installs `GhosttyKit.xcframework` (macOS universal slice, `arm64` iOS device slice, `arm64`+`x86_64` iOS simulator slice), Ghostty resources, and `libghostty-vt` headers/libraries under `apps/macos/.local/ghosttykit/` and `apps/macos/.local/ghosttyvt/`. The dynamic `libghostty-vt` runtime library is required (a static `.a` alone is incomplete: terminal transcript rendering loads it at runtime); the iOS app links `.local/ghosttyvt/lib/ghostty-vt.xcframework`, so a fresh worktree needs this setup before building iOS too. Every successful run also creates `.local/ghosttyvt/ios-link/` (symlinks to the device/simulator static libs, the `-L` the `ghosttyvtshim` target auto-links against; see `docs/implementation.md`), recreated on every run and outside the artifact cache.

```bash
apps/macos/scripts/setup_caddy.sh
```

Fetches a pinned universal Caddy binary into `apps/macos/.local/caddy/caddy`. App packaging invokes the same script before bundling Caddy into `Contents/Resources/caddy`; DMG installs link `/usr/local/bin/spaces-caddy` to it.

The Ghostty fork is the submodule at `apps/macos/vendor/ghostty`; the submodule pointer is the single source of truth for the commit used by both `GhosttyKit.xcframework` and `libghostty-vt`.

`setup_ghostty.sh` flags: `--download-only` (download and install this repo's `ghostty-artifacts-<sha>` release only; used by CI and publishing, fails on any manifest mismatch), `--build` (build from the submodule), `--allow-dirty` (only with `--build`: allow dirty Ghostty sources, marks the manifest dirty, local experiments only, never for PR/release), `--strict`, `--package DIR`. A source build installs the Zig version pinned by `ZIG_VERSION` in `setup_ghostty.sh` under `apps/macos/.local/ghosttyvt/toolchain/`.

Reuse order: local `apps/macos/.local/ghostty-artifacts/manifest.json` (matches when submodule SHA, script version, Zig version, Xcode build version, build-optimize mode, and host architecture all match; host architecture matters because `libghostty-vt` is host-native) -> the shared content-addressed cache -> the Spaces-owned GitHub release `ghostty-artifacts-<full-ghostty-sha>`. A downloaded release that validates except for Xcode build/optimize-mode/arch is left uninstalled and setup builds locally instead.

Manifest key fields cannot tell a correct artifact set from one whose content is wrong (compiled code that disagrees with its headers keys and validates identically), so the manifest also records `artifact_content_digest`: one SHA-256 over the installed trees (path+bytes per file, path+target per symlink, ordered by raw path bytes), computed after static-library normalization. Local reuse, cache restore, and download all recompute and compare it; a mismatch falls through the same chain a key mismatch does. Manifests under an older `schema_version` are invalid on every path, with no grandfathering.

Changing the Ghostty build flags `setup_ghostty.sh` passes to `zig build` requires bumping `BUILD_SCRIPT_VERSION` in that script (the manifest records no build flags, so artifacts built under old flags would otherwise keep validating). `apps/macos/Tests/setup_ghostty_*.sh` fixtures read that constant from the script. A drifted key (`BUILD_SCRIPT_VERSION`, `MANIFEST_SCHEMA_VERSION`, Zig version, or Xcode pin) makes `ensure_ghostty_artifacts.sh` classify the published release as invalid, so the next trusted publish rebuilds and republishes under the current key; `apps/macos/Tests/ensure_ghostty_artifacts_key_drift.sh` covers both directions against a stubbed release.

Every macOS workflow pins its Xcode version through `.github/actions/select-xcode` (the only place it's authored), because the artifact key includes the exact Xcode build version. Run the same Xcode locally to reuse prebuilt artifacts instead of rebuilding. To move the toolchain: bump `xcode-version` in that action, confirm the `macos-15` runner image ships it, install the matching Xcode locally; the next trusted publish republishes artifacts under the new build id.

Local source builds need Xcode's Metal Toolchain component (Ghostty compiles Metal shaders): `xcodebuild -downloadComponent MetalToolchain` (if Xcode reports first-launch packages need authorization, run `sudo xcodebuild -runFirstLaunch` first).

The shared cache lives at `apps/macos/.local/ghostty-cache`, keyed by `<ghostty-sha>/schema=...-script=...-zig=...-xcode=...-opt=...-arch=...`, derived from the checkout's Git common directory so every worktree on a machine shares one store; a tree that is not a Git checkout fails loudly rather than falling back to a private cache. `SPACES_GHOSTTY_CACHE_DIR` relocates it for hermetic setup tests. Every successful clean setup seeds the cache; dirty (`--build --allow-dirty`) builds are never written to it.

Setup finishes by running `apps/macos/scripts/verify_ghosttykit.sh`, which checks the artifact exports the embedded terminal APIs Spaces needs, and fails if any xcframework slice links Ghostty's Sentry crash reporter (Spaces builds with `-Dsentry=false`; Sentry's init thread races `ghostty_init`'s locale setup and segfaults `spacesd` and the iOS app).

### When a Spaces branch depends on Ghostty fork work

Edit and commit inside the submodule, push to the fork's `spaces` branch, then update the parent pointer:

```bash
git -C apps/macos/vendor/ghostty status --short --branch
git -C apps/macos/vendor/ghostty push origin HEAD:spaces
git add apps/macos/vendor/ghostty
```

The fork's own gate is the Zig suites run inside the submodule with the pinned Zig toolchain: `zig build`, `zig build test -Demit-xcframework=false -Demit-macos-app=false`, `zig build test-lib-vt`. Plain `zig build test` additionally builds and runs Ghostty.app's Xcode suite (`macos/GhosttyTests`, tests the upstream Swift app Spaces never links, needs macOS 26); that suite is not part of the gate. See the `ghostty-upstream-sync` skill for the full upstream-merge procedure.

PR checks run `ensure_ghostty_artifacts.sh` first (downloads/validates an existing `ghostty-artifacts-<sha>` release). Same-repo PRs, manual PR-check runs, and pushes to `main` first run a non-cancelable trusted artifact publisher that builds from the pinned submodule and publishes a reusable release when missing/incomplete; fork PRs build missing artifacts locally without publishing. After a release is published, refresh local artifacts and reverify from the primary checkout (which owns the shared cache the `rm` below clears, so setup exercises the download path rather than a cache restore):

```bash
git -C apps/macos/vendor/ghostty rev-parse HEAD
rm -rf apps/macos/.local/ghosttykit apps/macos/.local/ghosttyvt apps/macos/.local/ghostty-cache
apps/macos/scripts/setup_ghostty.sh
scripts/verify.sh
```

Spaces app releases run `ensure_ghostty_artifacts.sh --publish-missing` (consume a valid prebuilt release when available, else build and publish from the pinned submodule). For uncommitted local Ghostty experiments: `apps/macos/scripts/setup_ghostty.sh --build --allow-dirty` (the generated manifest is marked dirty and must not be used for PR or release workflows).

### Verifying the embedded terminal path

The app hosts no Ghostty surface of its own: every pane (including the local device's) is a `RemoteGhosttySessionHost` painting the daemon's render-frame stream over the Device API.

```bash
apps/macos/scripts/setup_ghostty.sh --build --allow-dirty
export SPACES_DB_PATH="$TMPDIR/spaces-ghostty-owner/spaces.db"
mkdir -p "$(dirname "$SPACES_DB_PATH")"
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/SpacesApp
```

Then open a workspace terminal, launch a workspace process with the terminal host set to Spaces, or run a coding-agent command in a workspace terminal; close and reopen the owner window, and quit/relaunch `SpacesApp` and reopen the same session; the shell should stay attached without restarting. CLI-created sessions (`spaces terminal create`, `spaces workspace start --workspace <id>`) use the same daemon-owned render-frame stream; `spacese2e` exposes `open-workspace-terminal`, `run-workspace-process`, and `start-workspace-terminal-session` to script the same paths without accessibility automation.

For a full isolated CLI smoke pass against the embedded backend (`terminal create`, `terminal list`, `terminal send text/bytes`, `terminal tail`, `mobile-status`, `terminal show`), export `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR` under an isolated temp root, run `setup_ghostty.sh`, launch `SpacesApp`, register a project with `spacese2e register-project --project-dir <dir>`, then drive the `spaces` CLI against it; see the commands used by `apps/macos/Tests/e2e_terminal_cli_commands.sh` (also runnable via `apps/macos/Tests/e2e.sh terminal --scenario cli`).

For built-in terminal verification, keep exactly one `SpacesApp` process running for the chosen profile root; live Ghostty rendering is owner-only on both macOS and iOS. Setup failures are covered under Troubleshooting.

## Linux Daemon Build and Test

Daemon-side unit suites (`#if os(Linux)` tests, plus the cross-platform `SpacesTestHostDetectionTests`) run in Docker:

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

On Linux the package manifest declares only the daemon-side target graph (the AppKit/SwiftUI client targets do not exist there), plus system-library targets standing in for Darwin frameworks (SQLite, OpenSSL, `CZlib`); each needs its dev package in both the builder image (`apps/macos/scripts/linux-builder-versions.sh`) and the test container's apt list (`run_linux_tests.sh`). Linux suites use Swift Testing rather than XCTest (corelibs-xctest deadlocks an async test before it starts). Each suite runs in its own `swift test --filter` invocation because every one of them mutates the process-wide `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR` in init/deinit, and each invocation is checked for a zero-match run (a `--filter` that matches nothing exits 0, so an uncompiled suite would otherwise sit green running nothing); a Linux suite must be in both the filter list and the Linux `sources:` whitelist for its test target in `Package.swift`.

Lower-level artifact build:

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

Zig/SwiftPM caches must live in named Docker volumes, never the bind-mounted workspace: POSIX locking over Docker Desktop's macOS file sharing can deadlock the ghostty-vt `zig build`. Use `--platform linux/amd64` with `--arch x86_64` for the Ubuntu x86_64 leg (both architectures build locally on Apple Silicon; x86_64 runs under emulation and takes longer). The archive contains `bin/spacesd`, `bin/spaces`, `install.sh`, `spacesd-bin`, `libghostty-vt`, and the Swift runtime libraries needed on stock Ubuntu 24.04. The Linux `zig build` passes `-Dcpu=baseline` so the artifact runs on every device of its architecture, not only CPUs as capable as the build host (a native build without it can emit EVEX/AVX-512 instructions that SIGILL on other machines); packaging asserts no EVEX-encoded instruction (`0x62` prefix) appears in the compiled x86_64 binaries.

A failure that reproduces only on CI's x86_64 runners (not locally under emulation) is hunted on a disposable GCP VM matching the runner's shape: `gcloud compute instances create <name> --machine-type=e2-standard-4 --image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud --boot-disk-size=60GB --max-run-duration=8h --instance-termination-action=DELETE` (self-deletes, ~$0.13/hour). Install `docker.io`, tar-pipe the worktree over `gcloud compute ssh` (the Linux test lane needs `apps/macos/.local/ghosttyvt/include` and `lib-linux` alongside sources), and loop `run_linux_tests.sh` under `setsid nohup` to get iteration times of tens of seconds instead of a CI round trip. Sharp edges: a trailing `... & tail` in an ssh command backgrounds the whole preceding chain and reconnects stdin to `/dev/null` (run sync steps as their own foreground ssh invocations and verify with a `grep`-able marker); `pkill -f` inside ssh can self-match; `timeout` around `docker run --sig-proxy=false` needs `-k` (the CLI ignores SIGTERM in that mode); an in-container `apt-get` can hang for hours with no output, so check long runs actively.

Every artifact build runs inside the Spaces Linux builder image (Swift toolchain, packages, pinned Zig), so a container starts compiling immediately. `apps/macos/scripts/ensure_linux_builder_image.sh --arch <arch>` prints the tag, building it first if missing; `apps/macos/scripts/linux-builder-versions.sh` defines the base image, packages, and Zig version. The tag is a digest of that definition, so changing it names a different image; `docker rmi` the tag to pick up a republished upstream base with the same tag.

### Linux deploy and profile lanes

```bash
apps/macos/scripts/deploy_linux_spacesd_e2e.sh --profile NAME
```

The one entry point that builds, caches, and uploads the Linux archive; every lane that installs a Linux daemon names the profile it installs into, keying the remote staging directory `~/.spaces/remote-artifact-e2e/<profile>/`. `installed` is refused as a profile name: every lane installs into a development profile (`~/.spaces-dev/profiles/spaces/<name>/`, `spacesd@<name>` systemd instance, its own Device API port) so the account's installed `~/.spaces` daemon and release-only status are never touched.

The build fingerprint covers `Package.swift`, `Package.resolved`, the artifact build script, the builder image definition, and the source directories of the `spacesd`/`spaces` dependency closure (derived from `Package.swift`, so a macOS-only change is a cache hit). The lane keeps a per-worktree pair of named Docker volumes, `spaces-linux-zig-<hash>` and `spaces-linux-swift-<hash>` (hash of the worktree's absolute path), each labeled `dev.usespaces.spaces.worktree`; `scripts/prune-linux-e2e-cache-volumes.sh` removes a volume whose labeled (or hash-matched) worktree no longer exists, scoped to the `spaces-linux-` prefix, never a blanket prune. `deploy_linux_spacesd_e2e.sh` runs it on the build path before creating this worktree's pair, and the `prune-merged` skill runs it once at the end of a pruning pass.

The bundled `install.sh` (`[--profile NAME] [--performance-log PATH]`) ignores the installing shell's `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR`/`SPACES_DEVICE_API_HOST`/`SPACES_DEVICE_API_PORT`/`SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH` entirely (inheriting them is what let one developer's worktree profile get baked into a device's single shared unit). With no arguments it installs the device's one installed profile (`~/.spaces/daemon/releases/<version>/`, `~/.spaces/daemon/current`, `~/.spaces/bin/{spaces,spacesd}`, `~/.local/bin/spaces`, `~/.spaces/runtime`, `~/spaces/{workspaces,repos}`, `~/.config/systemd/user/spacesd.service`). With `--profile NAME` everything lives under `~/.spaces-dev/profiles/spaces/NAME/` (stable path `daemon/current/bin/spacesd`), nothing under `~/.spaces` is touched, and the daemon runs as the `spacesd@NAME.service` instance of one shared template unit. `--performance-log PATH` is the one per-instance setting, applied as a `<unit>.d/performance-log.conf` drop-in, removed by any install that omits the flag. Either way the installer enables user lingering and the target unit; an already-running compatible daemon applies the image through the exec-in-place handoff via the target profile's own `spaces` binary. If the account cannot enable lingering itself: `sudo loginctl enable-linger <user>` on the device.

The single user-facing Linux install/upgrade path is `scripts/spaces-install-linux.sh`, served at `https://usespaces.dev/install.sh` (republished by `apps/web`'s npm `prebuild` on every website deploy, not a per-release GitHub asset):

```bash
curl -fsSL https://usespaces.dev/install.sh | bash                    # latest release
curl -fsSL https://usespaces.dev/install.sh | bash -s -- <version>    # pinned version (printed by clients when pairing needs a specific wire version)
```

The no-version form resolves through GitHub's `releases/latest/download` redirect, so it only works while Spaces releases hold the repo's "latest" marker (release workflows use `--latest`; `ensure_ghostty_artifacts.sh` publishes `ghostty-artifacts-<sha>` releases as prereleases so they never capture it).

For an unreleased build, install locally via scp + the bundled `install.sh`:

```bash
scp .build/artifacts/spacesd-ubuntu-24.04-x86_64.tar.gz <host>:/tmp/
ssh <host> 'mkdir -p /tmp/spacesd-install && tar -xzf /tmp/spacesd-ubuntu-24.04-x86_64.tar.gz -C /tmp/spacesd-install && /tmp/spacesd-install/install.sh'
```

Verify remote pairing over strict SSH (the Mac app's `--ssh` pairing path runs the same command):

```bash
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes <host> '~/.spaces/bin/spaces device pair --json'
```

Remote Macs install from the signed DMG instead: it creates `/Applications/Spaces.app`, links `/usr/local/bin/{spaces,spacesd,spaces-caddy}` and `~/.spaces/bin/{spaces,spacesd}` to the bundled binaries, writes the per-user LaunchAgent, and creates the default `~/.spaces` state directories.

## Manual E2E, Latency, and Profiling

`apps/macos/Tests/e2e.sh` is a thin wrapper: it builds `spacese2e` and execs `spacese2e e2e "$@"`. The **`e2e` skill** owns lane selection, environment prerequisites, and the flake-vs-regression judgement; this section is the reference for invocation, flags, and what each scenario asserts or measures. The scenario tables in `apps/macos/Sources/spacese2e/E2ERunner.swift` are the single source of truth for lane/scenario names; `--list` prints a lane's scenarios.

```bash
apps/macos/Tests/e2e.sh <app|terminal|mobile|device-api [target]|all|exhaustive|mobile-demo|mobile-baseline> [--scenario <name>] [--list]
```

`all` is the shared-setup smoke lane (app, terminal, mobile, paired-device coverage); `exhaustive` is the full manual lane (app full coverage, every terminal/mobile scenario, local+remote Device API parity, latency profiling). Each invocation writes a Markdown report under `apps/macos/.artifacts/e2e-runs/<timestamp>-<lane>/summary.md` (command timeline, per-case timing, per-step logs, flattened metric tables, links to raw JSONL).

Remote-host lanes read `.env` (gitignored, repo root) via `scripts/spaces-e2e-env.sh`; local-only scenarios run without it. The keys they read are `SPACES_E2E_REMOTE_SSH_HOST`, `_SSH_USER`, `_SSH_PORT`, `_DAEMON_HOST`, `_WORKSPACE_ROOT`, `_GIT_ROOT`, and `_NAME` (see `.env.sample`); they drive the remote Device API lanes, `spacese2e profile --remote`, and the Linux deploy/cleanup scripts. A remote daemon's port and profile root are derived at runtime, not configured, so other keys under that prefix (`_DAEMON_PORT`, `_HOST_ID`, `_AUTH_TOKEN`) are read by nothing. A fresh worktree has no `.env`; copy one from a configured checkout (`cp ~/projects/spaces/.env .env`). Never commit `.env`.

### App lane

```bash
apps/macos/Tests/e2e.sh app
apps/macos/Tests/e2e.sh app --scenario smoke
```

Seeds the shared Harbor/Lantern/Atlas fixture repos and runs launch, focus, cycling, workspace, and agent-status assertions against the current profile's same-machine daemon. With `SPACES_E2E_RUN_REMOTE=1`, also prepares a paired remote Linux daemon from `.env`, seeds the Mac client with that device, starts a remote service, and verifies it through the Mac Caddy router over an SSH local forward.

Primary coverage: adding/deleting a workspace, overriding workspace settings, launch/stop/restart/dead-process recovery, built-in terminal coverage, extra user-added Chrome/terminal tabs, numbered focus shortcuts, forward/back window cycling, multi-workspace focus/cycling isolation, remote browser-session routing.

The suite is also the primary path for window-focus/cycle latency profiling: it prints pass/fail plus timing samples (count, p50, p95, max). `app window-cycle` runs the full window-cycle profile (`REAL_SYSTEM_PROFILE_WARMUPS=5 REAL_SYSTEM_PROFILE_REPETITIONS=30` for steady-state samples); `app window-cycle-small` runs a faster primary-workspace-only loop (`--samples N`, or `REAL_SYSTEM_PROFILE_WARMUPS=0` for a quick local probe). Measure before and after a candidate optimization with identical warmup/repetition counts; only optimize phases whose p95 is at least 15ms or at least 20% of that flow's total p95. `DEBUG=1` app perf lines split focus work into named phases (shortcut dispatch, target resolution, client DB lookup/write, Chrome AppleScript, existing-pane focus, pane open, ownership request, focus observation, route time, total elapsed).

The suite appends aggregated history to `apps/macos/.artifacts/real-system-profiles/metrics-history.csv` and regenerates `report.html` (best/previous/latest per tracked metric, deltas in ms and percent, dirty-worktree fingerprinting). Debug-log lines that are test contracts (do not change without updating the suite): `spaces: perf metric=...`, `spaces: workspace_detail_ipc selecting ...` / `selected ...`.

### Terminal lane

```bash
apps/macos/Tests/e2e.sh terminal --scenario cli                          # spaces terminal create/send/key/tail/show + both takeover directions
apps/macos/Tests/e2e.sh terminal --scenario daemon-exec-handoff          # exec-in-place update handoff
apps/macos/Tests/e2e.sh terminal --scenario daemon-signal-shutdown       # SIGTERM -> graceful finalize
apps/macos/Tests/e2e.sh terminal --scenario daemon-idle-shutdown         # idle-shutdown path
apps/macos/Tests/e2e.sh terminal --scenario session-restore              # coding-agent restore after daemon death
apps/macos/Tests/e2e.sh terminal --scenario agent-orchestration          # spaces agent list/status/brief/subscribe/kill
apps/macos/Tests/e2e.sh terminal --scenario edit-shortcuts               # Cmd+V/C/F/G/Shift+G/Esc
apps/macos/Tests/e2e.sh terminal --scenario mouse-reporting-scroll
apps/macos/Tests/e2e.sh terminal --scenario stress                       # lines / repaint / mixed / codex_churn
apps/macos/Tests/e2e.sh terminal --scenario soak --duration-seconds 300
apps/macos/Tests/e2e.sh terminal --scenario built-in-terminal-profile --samples 3
apps/macos/Tests/e2e.sh terminal --scenario workspace-terminal-open --samples 3
apps/macos/Tests/e2e.sh terminal --scenario spaces-terminal-hotkeys --samples 3
apps/macos/Tests/e2e.sh terminal --scenario spaces-terminal-palette --samples 3
apps/macos/Tests/e2e.sh terminal --scenario workspace-process-terminal
```

`daemon-exec-handoff` (`e2e_daemon_exec_handoff.sh`): flips a `bin/spacesd` symlink to a second on-disk copy of the same build and pokes with `spaces daemon apply-update`; proves the daemon pid is unchanged (exec, not respawn), the session's child pid survives, `handoff_resume generation=N` lands in the log, pre-handoff scrollback survives, live I/O keeps flowing, and repeats once more (`generation=2`).

`daemon-signal-shutdown` (`e2e_daemon_signal_shutdown.sh`): sends `SIGTERM` directly to the daemon pid (not the control socket) and asserts the session's `terminal_runtime_states` row finalizes to `exited` rather than sticking at `running`; the discriminating check that the signal ran the same graceful teardown as `.shutdown`.

`session-restore` (`e2e_session_restore.sh`): runs on a throwaway profile under a temp `HOME`. Spawns a fixture coding agent, kills the daemon outright, and asserts `daemonStatus` offers the stranded agent and `restoreSessions` resumes it with its `-s <key>` argument; then `SIGTERM`s the daemon while the restored agent is running and restores it again; then drives `apply-update` and checks the handoff keeps the agent running with nothing left to restore.

`agent-orchestration` (`e2e_agent_orchestration.sh`, daemon+CLI only, no app/desktop control): Part A drives the lifecycle via explicit `spaces agent signal` events with no real agents: `init` produces a ready row, a brief piped to `agent brief write` on stdin survives a later `working` signal (the rows carry its headline) and reads back verbatim through `agent brief read`, `subscribe`+`blocked` injects the `[spaces] ... open: spaces://terminal/<id>` line, a `done` for a busy subscriber queues and flushes on idle (the flushed block carries the `brief:` headline line), a cycle-closing subscribe is rejected, `kill` removes the row, plus a spawn-failure case and a fixture-agent spawn-detection case, and a hookless-exit case (codex/opencode-style) that asserts exactly one `is exited` block naming `(codex)`. Set `SPACES_E2E_AGENT_MATRIX=1` for the opt-in real-provider matrix (Part B): for each of `claude`/`codex`/`opencode` present on `PATH` with current hooks, spawns it, records `provider=%s detected=%s spawn_ms=%s first_signal=%s signal_sequence=%s saw_reply=%s`, submits a trivial prompt, and kills it; a missing/stale provider is reported `SKIP` and does not fail the run.

`stress` scenarios against the embedded Ghostty backend: `lines` (high-volume append-only), `repaint` (full-screen ANSI clears/redraws), `mixed` (status repaints + ordered emission), `codex_churn` (the primary large-churn regression scenario: long scrollback plus Codex-style prompt/transcript/spinner/footer/cursor-move churn). Each verifies ordered `SEQ` markers, the final frame and `tail` view, and reports `tail_min/median/avg/p95/max`, output-log growth, and `terminal_output_write`/`terminal_surface_refresh`/`terminal_tail_read`/`terminal_tail_command` metrics.

`soak --duration-seconds N` supports `SOAK_MODE=repaint|mixed|codex_churn` (alias `codex`); samples `SpacesApp` RSS, CPU, output growth, and tail latency at a fixed interval, reports early-vs-late drift, and confirms sequence completeness and the final frame after the run.

`agent-orchestration`'s orchestration surface (`spaces agent` list/status/brief/subscribe/kill and notification injection) and `soak`/`stress` require no app; `built-in-terminal-profile`, `workspace-terminal-open`, `spaces-terminal-hotkeys`, `spaces-terminal-palette`, `workspace-process-terminal`, and `edit-shortcuts` run against the app with an isolated `SPACES_DB_PATH` (several with `DEBUG=1`), summarizing named phase metrics printed in each scenario's own output. `spaces-terminal-hotkeys` drives `Cmd+Opt+=` dismiss/summon; `spaces-terminal-palette` drives `Cmd+Opt+-` and asserts focus stays on the process selected from the palette even while another owns focus.

For the scheduled-automations surface (`spacese2e automation-create`/`-update`/`-delete`/`-list`/`-runs`/`-trigger`/`-cancel`/`-end-agents`, the same profile-socket commands the app's Automations UI sends; there is no end-user `spaces automation` CLI):

```bash
apps/macos/Tests/e2e_automations.sh
```

Daemon-only (no app/desktop control), binds to the current worktree profile via `spacese2e profile-show --shell`. Scenarios a-e use fake scripts (`--script`): manual success/failure exit codes, `concurrency=skip` behavior, a 2-second timeout, and `SPACES_AUTOMATION_RUN_ID` attribution. Scenario f covers `--kind agent` edge cases without a real provider (unresolvable workspace refused; End-agents on a terminal run is a no-op). Scenario g is the real-provider lane (`claude --model haiku`): asserts the prompt reached and was answered exactly once; skips (passing) when no `claude` is on `PATH` or the fixture path shows a folder-trust dialog. The script deletes every automation it creates, which also cancels any still-running run.

To exercise a cron schedule locally: create with `--cron '<minute> * * * *'` a minute or two out and poll `automation-runs --automation-id <id>`.

### Mac and iOS terminal latency

```bash
apps/macos/Tests/e2e.sh terminal --scenario mac-input-latency
apps/macos/Tests/e2e.sh terminal --scenario mac-scrollback-latency          # large scroll deltas
apps/macos/Tests/e2e.sh terminal --scenario mac-scrollback-partial-latency  # small within-screen deltas
apps/macos/Tests/e2e.sh mobile --scenario ios-input-latency --network-profile local
apps/macos/Tests/e2e.sh mobile --scenario ios-input-latency --network-profile ios-constrained
apps/macos/Tests/e2e.sh mobile --scenario ios-scrollback-latency --network-profile local
apps/macos/Tests/e2e.sh mobile --scenario ios-scrollback-latency --network-profile ios-constrained
```

Fast performance-iteration lanes, not the correctness gate. They write `terminal-latency-summary.json` (p50/p95/max, per-sample timings, visible render-frame mix, median render-update bytes, payload rates) and fail on gross latency regressions, render-frame decode failures, or a typed echo arriving as a full/missing/`explicit_resync` frame instead of a live delta. Both scroll scenarios drive the scroll as a direct `scroll` control-command RPC (not a captured trackpad gesture), so they exercise the daemon's export/apply path regardless of client wheel routing. The `ios-constrained` profile shapes standalone Device API requests with 80ms RTT / 8Mbps / 16KB chunks, selected via the test-only `SPACES_DEVICE_API_NETWORK_PROFILE` env var (the daemon-supervised path always uses the default local profile).

```bash
apps/macos/Tests/e2e.sh mobile --scenario ios-input-latency --network-profile local --samples 12 --keep-root
apps/macos/Tests/render_update_profile_summary.py \
  --performance-log <work-root>/mobile-terminal-performance.jsonl \
  --summary-json <work-root>/terminal-latency-summary.json \
  --render-mode production --sample-count 12 --network-profile local --target ios-input-latency
```

Writes normalized JSON under `apps/macos/.artifacts/terminal-render-profiles/` (git SHA, Ghostty submodule SHA, byte totals, average bytes/update, peak 1s/10s bandwidth, frame mix, latency percentiles, encode/decode/apply CPU-proxy totals, drop/resync/refresh counts).

### Device API parity

```bash
apps/macos/Tests/e2e.sh device-api local
apps/macos/Tests/e2e.sh device-api remote
apps/macos/Tests/e2e.sh device-api                                        # local + remote
apps/macos/Tests/e2e.sh device-api latency-compare --samples 12 --keep-root
apps/macos/Tests/e2e.sh device-api profile                                # ownership-transfer profiling
```

`local`/`remote` create a project and workspace, open/stop a workspace terminal, run/restart/stop a configured process, and stop a live coding agent; `remote` installs its own `remote-device-e2e` development profile (installed profile untouched) and also verifies the Device API service tunnel (`spacese2e service-tunnel`, an HTTP GET through the paired daemon to a running `web` service; a missing service fails `notFound`). Both write `terminal-latency-summary.json` open/state/send timing.

`latency-compare` creates one remote Device API workspace and compares it against a local Spaces terminal SSHed into the same directory, writing `remote-terminal-latency-compare-summary.json` (p50/p95/max for `remote-workspace` vs `local-workspace-ssh` across input-echo, command-output, and scrollback scenarios, plus p95 delta/ratio and phase breakdowns). Remote Device API runs cache the Linux daemon archive under `apps/macos/.build/linux-e2e-cache/artifacts/` (source fingerprint), skip re-upload on a matching checksum, and reuse a healthy installed daemon when the artifact checksum and port marker match.

`profile` pairs a first-party iOS-shaped installation and measures time-to-owner-render, ownership transfer to/from iOS, and streamed input visibility latency both directions.

Remote terminal orchestrator path end-to-end:

```bash
apps/macos/Tests/e2e_remote_terminal_send.sh
```

Builds and uploads this worktree's Linux daemon with `deploy_linux_spacesd_e2e.sh`, installs it into the `remote-device-e2e` development profile, pairs the CLI over SSH (`spaces device pair`), creates a remote session, and drives it with `spaces terminal list/send/tail --device`, using an isolated client DB and secret directory.

### Render-update profiling and control-lane profiling

```bash
SAMPLES=120 PRODUCERS=5 apps/macos/Tests/profile_device_api_control_lanes.sh
```

Runs its own throwaway profile/daemon, streams `PRODUCERS` bursty agent-shaped sessions at ~100KB/s each, resyncs each with `.state`, runs a sidebar-shaped `.overview` poll, and reports p50/p95/max for the typed control round trip, `.overview`, and the DEBUG-gated `device_api_control_lane_wait` metric. Runs with `DEBUG=1`, so absolute numbers are only comparable against another run of this script. Nothing is published unless the run is comparable (perf log armed, every producer stayed alive, the `.overview` poll ran to completion unrejected); otherwise it prints what went wrong and exits nonzero.

### iOS build and manual simulator verification

`apps/ios/SpacesMobile.xcodeproj` is generated by XcodeGen from `apps/ios/project.yml` and committed with explicit source listings. After adding/removing a file under `apps/ios/{Sources,Tests,SmokeUITests,UITestSupport,UITests}`, run `xcodegen generate` in `apps/ios` and commit the regenerated `project.pbxproj`, or the build fails on a missing symbol.

```bash
export SPACES_DB_PATH="$TMPDIR/spaces-ios-demo/spaces.db"
mkdir -p "$(dirname "$SPACES_DB_PATH")"
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/SpacesApp
mkdir -p "$TMPDIR/spaces-ios-demo/workspace"
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/spacese2e register-project --project-dir "$TMPDIR/spaces-ios-demo/workspace" >/dev/null
(cd "$TMPDIR/spaces-ios-demo/workspace" && env SPACES_DB_PATH="$SPACES_DB_PATH" "$(cd apps/macos/.build/debug && pwd)/spaces" terminal create --command cat --title ios-demo)
env SPACES_DB_PATH="$SPACES_DB_PATH" apps/macos/.build/debug/spacese2e mobile-status
xcodebuild -project apps/ios/SpacesMobile.xcodeproj -scheme SpacesMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

On first launch the iOS client opens its Devices sheet; open Devices in the Mac sidebar (or `spaces device pair`) and scan the QR code. The daemon Device API binds all IPv4 interfaces on port `47847` by default, so `127.0.0.1` works from the simulator. After pairing, the client stores the issued credential and pinned daemon fingerprint and reconnects automatically.

For a real device: connect and trust the Mac, enable Developer Mode; `cp .env.sample .env` and set `SPACES_IOS_DEVICE_UDID` from `xcrun xctrace list devices`; run `scripts/install-ios-device.sh` (builds, installs, launches with `SPACES_MOBILE_PAYWALL_BYPASS=1` so the Debug build skips the subscription gate; launching from the home screen shows the real gate, which needs the subscription in App Store Connect; run from Xcode to exercise the paywall with the local StoreKit fixture). If Xcode cannot sign `dev.usespaces.spacesmobile`, widen the first-party bundle policy rather than changing the bundle id (the Device API accepts only that id for pairing/reconnect); `SPACES_IOS_DEVELOPMENT_TEAM` in `.env` overrides the signing team. Keep the Mac app and Device API on the same `SPACES_DB_PATH`. On the Mac, allow the incoming-network prompt, open Devices, "Pair iPhone" on the target row, and scan; accept the iOS local-network permission prompt on first connect.

### iOS performance baseline lane

An on-demand, fully automated lane: XCUITest drives the iOS app in a simulator against a live daemon (local dev daemon, or this worktree's remote Linux dev profile) through a Mac-side shaping proxy. Not part of `verify.sh` or CI; run by hand when a change might move device-side timing, payload size, or reconnection behavior. It measures only: a slow number never fails the run, only a broken precondition does.

Eleven scenarios (`cold-open`, `cold-open-owned`, `back-and-forth`, `keyboard`, `streaming`, `scrollback`, `background-terminal`, `background-list`, `reconnect`, `idle`, `mac-reconnect`) run under three shaped network profiles, both directions:

| profile | one-way delay | bandwidth (each direction) |
|---|---|---|
| good | 10 ms (20 ms RTT) | 50 Mbit/s |
| constrained | 40 ms (80 ms RTT) | 8 Mbit/s |
| poor | 200 ms (400 ms RTT) | 1 Mbit/s |

`cold-open-owned` is local-only (a Mac window owns the session before the UI test runs, via `spaces terminal show`, which stages this worktree's Mac app if not already running); `reconnect` scripts a dead link through the shaping proxy's control port; `mac-reconnect` measures the same link-down/link-up procedure on the Mac client's own paired-device pane, against a throwaway daemon of its own (an ephemeral profile under the run root), reporting to a "Mac reconnect" table with a "stranded dials" column.

```bash
apps/macos/.build/debug/spacese2e e2e mobile-baseline
```

`--remote` targets this worktree's remote Linux dev profile (deploy first with `dev-build-and-launch.sh`, no `--local`). The wrapper forwards only `--remote`; `--profile <name>`/`--scenario <name>` (repeatable) and `--idle-seconds N` (default 120) are accepted by `apps/macos/Tests/e2e_mobile_baseline.sh` directly: `SPACES_E2E_SKIP_MACOS_BUILD=1 SPACES_E2E_SKIP_GHOSTTYKIT_SETUP=1 apps/macos/Tests/e2e_mobile_baseline.sh --profile good --scenario cold-open`.

The runner turns off Simulator's "Connect Hardware Keyboard" for the run (needed for the `keyboard` scenario's software-keyboard transition) and restores it after. Only `streaming` enables the app's E2E render dump, so its frame timings include one file write per frame that no other scenario pays.

Each run gets its own root under `~/.spaces-dev/ios-baseline/<UTC timestamp>/` (`device-perf.jsonl`, `shaper.jsonl`, `sessions.json`, one `xcodebuild-<profile>-<scenario>.log` per scenario, `runner.log`, `report.md`). To compare before/after, run the lane in two worktrees (or two commits) with identical flags and read the two `report.md` files side by side; there is no built-in compare mode or stored baseline.

### Mobile demo stack

```bash
apps/macos/Tests/e2e.sh mobile-demo
apps/macos/Tests/e2e.sh mobile-demo --local   # local Mac daemon only, no remote artifact/pairing/`.env` needed
```

Launches the macOS app, pairs both iPad and iPhone simulators against the daemon-hosted Device API, provisions live Harbor/Lantern workspace terminal sessions, and (unless `--local`) installs the Linux E2E artifact on the configured remote and pairs it too. Prints demo root, profile mode, PIDs, logs, screenshots, session IDs, and remote device details as JSON; keeps the stack alive until `Ctrl+C`, then tears down cleanly. Demo runs use the current user's `HOME`/`XDG_CONFIG_HOME` (so Ghostty themes/settings match local debugging); by default the database/runtime live under the demo root (`SPACES_MOBILE_DEMO_PROFILE_MODE=user` attaches to the repo-local profile instead). The demo root also holds `mobile-terminal-performance.jsonl`.

Overrides: `SPACES_MOBILE_DEMO_KEEP_ROOT=1`, `SPACES_MOBILE_DEMO_PROFILE_MODE=isolated|user`, `SPACES_MOBILE_DEMO_ROOT_PARENT=...` (default `~/.spaces-dev/mobile-demo`), `SPACES_MOBILE_DEMO_BUILD_MACOS=0`, `SPACES_MOBILE_DEMO_IPAD_NAME=...`/`_IPHONE_NAME=...`, `SPACES_MOBILE_DEMO_APP_PATH=...`, `SPACES_MOBILE_DEMO_PORT=...` (default `0`, daemon picks a free port), `SPACES_MOBILE_E2E_DEVICE_KEY=iphone|ipad` / `_DEVICE_NAME=...` (E2E default target: `iPhone 17 Pro`).

Targeted mobile UI scenarios:

```bash
apps/macos/Tests/e2e.sh mobile --scenario takeover
apps/macos/Tests/e2e.sh mobile --scenario codex                              # real Codex TUI + iPhone takeover
apps/macos/Tests/e2e.sh mobile --scenario codex-resume-reopen
apps/macos/Tests/e2e.sh mobile --scenario roundtrip                          # Mac/iPhone/Mac/iPhone/Mac ownership path
apps/macos/Tests/e2e.sh mobile --scenario scrollback
apps/macos/Tests/e2e.sh mobile --scenario mouse-reporting-scroll
apps/macos/Tests/e2e.sh mobile --scenario two-session
apps/macos/Tests/e2e.sh mobile --scenario ctrl-c-final-frame
apps/macos/Tests/e2e.sh mobile --scenario ctrl-c-final-frame-codex-survivor
apps/macos/Tests/e2e.sh mobile --scenario ownership-guard                    # Device API ownership rules, no UI automation
```

`codex` scenarios build a generated Codex home inside the demo root (copies current config, links signed-in auth, marks the demo project trusted) so the harness exercises the real TUI. Overrides: `SPACES_MOBILE_CODEX_COMMAND`, `SPACES_MOBILE_CODEX_RESUME_THREAD_ID`, `SPACES_MOBILE_CODEX_HOME` (default the current `CODEX_HOME` or `~/.codex`), `SPACES_MOBILE_GHOSTTY_XDG_CONFIG_HOME` (default `XDG_CONFIG_HOME` or `~/.config`).

Terminal rendering rules that E2E enforces: `GhosttyRemoteTerminalView` must not render from raw output bytes or call local session-export APIs to reconstruct another owner; mobile owner bootstrap and macOS owner attach/takeover must use the same service-published live Ghostty render frame. No VT replay, snapshot-to-VT encoding, raw output, or `output.log` as a rendering fallback.

### Screenshot staging

```bash
xcodebuild -project apps/ios/SpacesMobile.xcodeproj -scheme SpacesMobile \
  -destination "platform=iOS Simulator,id=$IPHONE_UDID" -derivedDataPath apps/macos/.build/ios-derived-data \
  -only-testing:SpacesMobileUITests/SpacesMobileScreenshotUITests build-for-testing

TEST_RUNNER_SPACES_MOBILE_UI_TEST_CONFIG_PATH="$UI_TEST_CONFIG" \
TEST_RUNNER_SPACES_MOBILE_SCREENSHOT_TAB=agents \
TEST_RUNNER_SPACES_MOBILE_SCREENSHOT_HOLD_SECONDS=45 \
xcodebuild -project apps/ios/SpacesMobile.xcodeproj -scheme SpacesMobile \
  -destination "platform=iOS Simulator,id=$IPHONE_UDID" -derivedDataPath apps/macos/.build/ios-derived-data \
  -only-testing:SpacesMobileUITests/SpacesMobileScreenshotUITests/testScreenshotStaging test-without-building &
sleep 33 && xcrun simctl io "$IPHONE_UDID" screenshot /tmp/agents-tab.png
wait
```

`SpacesMobileScreenshotUITests` navigates to a chosen screen and holds it idle; a host process captures with `simctl io ... screenshot`. Each env var needs the `TEST_RUNNER_` prefix (`xcodebuild` strips it before forwarding to the in-simulator runner). Connect a hardware keyboard for the simulator (`defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool true`) so terminal screens capture without the software keyboard covering the lower half.

`SPACES_MOBILE_SCREENSHOT_TAB` selects `alerts|spaces|agents|settings`. `SPACES_MOBILE_SCREENSHOT_OPEN_ROW` (with `TAB=spaces`) taps the first row whose title contains the given text. `SPACES_MOBILE_SCREENSHOT_PAYWALL=1` renders `PaywallView` instead of navigating tabs (the price line stays on its loading state in-simulator since StoreKit has no catalog without App Store Connect; capture the real subscription-review screenshot from a TestFlight/production build). `SPACES_MOBILE_SCREENSHOT_DEMO=1` stages the same screenshots from Demo Mode instead (paywall bypass, reset to not-paired, enable Demo Mode); no mobile-demo stack, config file, or `.env` needed.

Build `$UI_TEST_CONFIG` from the mobile-demo stack's printed `deviceAPIHost`/`deviceAPIPort` plus the matching device entry in `<demo root>/pairing.json` (needs `host`, `port`, `authToken`, `certificateFingerprint`, `installationID`).

## Demo Mode Recording and App Review

The iOS app ships an in-app Demo Mode that tours the app from a bundled sample recording with no daemon, network, or account; what the App Store reviewer uses after a free sandbox purchase (design in [`docs/implementation.md`](implementation.md#ios-demo-mode), UX in [`docs/spec.md`](spec.md)).

Re-record when the fixture content (`apps/macos/Tests/fixtures/e2e_demo`), the render-update wire format, or the iOS viewer grids change:

```bash
apps/macos/Tests/record_ios_demo_recording.sh
```

Builds the debug products, seeds the storytelling fixture into an isolated profile, stages three workspace states, records each session at the iOS-native grids, enforces the 10MB bundle budget, and writes `apps/ios/Resources/DemoRecording/`. Idempotent (fresh temp profile per run), deterministic up to semantically identical decoded output. Commit the regenerated bundle.

Run before every submission, on a booted simulator:

```bash
xcodebuild -project apps/ios/SpacesMobile.xcodeproj -scheme SpacesMobile \
  -only-testing:SpacesMobileUITests/SpacesMobileDemoModeUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath apps/macos/.build/ios-derived-data test
```

Launches with only `SPACES_MOBILE_PAYWALL_BYPASS=1` and a render-dump path (no host/seed/daemon env), enters Demo Mode from the empty state, asserts the sample workspaces/alerts/agents/read-only transcript, and that turning Demo Mode off returns to the not-paired empty state. Persistence keys are shadowed through the argument domain so a shared simulator's prior state cannot make it flaky. Not part of `scripts/verify.sh`; this is the manual submission gate.

Produce App Store screenshots from Demo Mode with the same `testScreenshotStaging` invocation, adding `TEST_RUNNER_SPACES_MOBILE_SCREENSHOT_DEMO=1` (no stack or config file needed).

## Pre-commit Hook

```bash
git config core.hooksPath .githooks
git config --get core.hooksPath   # expect: .githooks
```

`.githooks/pre-commit` runs `scripts/verify.sh`. GitHub Actions [`pr-checks.yml`](../.github/workflows/pr-checks.yml) runs the same Swift verification flow and the iOS test lane, the static website build, and the Linux artifact builds on native x86_64 and arm64 runners (the x86_64 leg also runs the Linux unit-test lane). On a pull request the Swift, iOS, and Linux jobs run only when something besides docs (`docs/`, any `.md`) and the website changed, and the website build only when `apps/web/` or the release staging script changed; the always-running `gate` job is the single required check.

## QA Against the Shipped Build

QA of a released build runs the installed `/Applications/Spaces.app` against a throwaway profile at `~/.spaces-dev/qa`, seeded from a copy of `~/.spaces`, so a sweep can create, mutate, and delete freely while the installed profile stays untouched. The **`qa` skill** owns the sweep methodology (baselines, slopes, agent-orchestration pass, triage); this is the reference for the profile mechanics.

```bash
apps/macos/.build/debug/spacese2e qa-profile create
apps/macos/.build/debug/spacese2e qa-profile launch
apps/macos/.build/debug/spacese2e qa-profile deploy-remote   # optional: the Linux daemon half, when a device is configured
apps/macos/.build/debug/spacese2e qa-profile stop
apps/macos/.build/debug/spacese2e qa-profile remove
```

`create` copies the installed daemon and client databases via SQLite's online backup API (safe while the installed daemon serves them) and strips what the QA profile must not inherit: paired devices, terminal sessions and their coding-agent/client/attachment/remote-subscription rows, running processes, runtime targets, queued or executing automation runs, and the router port. Device identity, TLS material, auth tokens, and the runtime directory are not copied (the QA profile generates its own). Projects, workspaces, their settings, ports, and automations come across (automations disabled, since the copied workspaces name real repository directories); unfinished workspace setup resolves to succeeded. It refuses if `~/.spaces-dev/qa` already exists (`remove` first) or if the snapshot's schema version is newer than the checkout knows (run from a checkout at or ahead of the installed build).

`launch` starts the installed executable with `SPACES_DB_PATH` naming the QA database (set only in the launched process's environment, never exported), waits for the QA profile's app-owner lease, and logs to `~/.spaces-dev/qa/qa-app.log`. It starts the bundled `spacesd`, never the installed LaunchAgent job. `launch` and `deploy-remote` refuse to run when the calling shell binds anything that would redirect a shipped binary off the QA profile (`SPACESD_EXECUTABLE`, `SPACES_RUNTIME_DIR`, `SPACES_CADDY_EXECUTABLE`, the `SPACES_DEVICE_API_*` trio, `SPACES_DB_PATH`, `SPACES_CLIENT_DB_PATH`, `SPACES_CLIENT_SECRET_DIR`, `SPACES_GHOSTTY_RESOURCES_DIR`).

Inherited projects/workspaces keep their real `dir`, so they are material to read and measure, not to delete/start/restart; do lifecycle passes on a fixture project the sweep adds for itself. Sparkle runs as usual (an update prompt is real); desktop control (global hotkey, window cycling) reaches the QA app only while the installed app is not running.

`stop` stops the app named in the QA profile's own app-owner lease and asks the daemon on the QA profile's own socket to shut down (both are addressed per-profile, never by process name, since the QA daemon is the same `spacesd` binary as the installed one). `remove` deletes `~/.spaces-dev/qa` once neither is running.

`deploy-remote` reads the installed app's version from its `Info.plist`, downloads and sha256-verifies the matching `spacesd-ubuntu-24.04-<arch>` release artifact, and runs `install.sh --profile qa` on the configured device (`~/.spaces-dev/profiles/spaces/qa/`, `spacesd@qa.service`), then pairs with the installed `spaces` CLI bound to the QA database. Tear down with `spacese2e profile remove --remote qa`.

## Website

Local commands, the `prebuild` step, and where content lives are in [`apps/web/README.md`](../apps/web/README.md). `scripts/make-readme-device-art.py` regenerates the README's device-framed product shot (`docs/media/readme-ios.png`) from the screenshots in `apps/web/public/media/`.

## Version Metadata

`apps/macos/AppVersion.plist` is the only place a Spaces version is authored:

```bash
scripts/sync-app-version.sh --short <version> --build <build-number>
```

Generates: `apps/macos/Sources/workspacecore/AppVersion.swift` (constants the CLI, app menu, and daemon report), `apps/macos/Sources/SpacesApp/Info.plist` (regenerated wholesale from a template in the script; add a new key to that template, never the generated file), and `apps/ios/Info.plist` (version keys rewritten in place, hand-maintained keys left alone). Never hand-edit any of the three. `AppVersionMetadataTests` fails the build on any drift between the source and either bundle. See the Version Metadata Rules in `AGENTS.md` for the cross-client policy.

## macOS Release

```bash
scripts/release-and-deploy.sh <version> [build-number]
```

In CI the same release is cut by pushing a version tag (`.github/workflows/release.yml`, a thin caller of `release-build.yml`); see the **`release-by-tag` skill** for the guided procedure. Every tagged release publishes as a GitHub prerelease and reaches the stable feed only when promoted (below). Local release runs the Ubuntu daemon artifact builds inside Docker for both architectures, so Docker must be available.

The workflow: syncs version metadata; builds universal `arm64`+`x86_64` release binaries for the app, CLI, and `spacesd`; code-signs them and bundled Caddy; builds and smoke-tests both Ubuntu 24.04 artifacts (including an `apply-update` reinstall leg that asserts the exec-in-place handoff preserves the daemon pid and its live session); signs `spaces-remote-artifacts.json` with the remote-artifact Ed25519 key the Linux installer verifies against; builds and signs `Spaces.app` once, then optionally notarizes/staples it (`NOTARIZE=1`); packages the DMG and the Sparkle zip from that same signed bundle; updates `dist/updates/appcast.xml` and Sparkle delta files; optionally notarizes/staples the DMG itself (a distinct artifact Gatekeeper evaluates on its own; the zip carries no notarization ticket of its own and relies on the stapled app inside it); verifies the final DMG signature and bundled binaries; publishes the DMG, Sparkle zip, `appcast.xml`, both Linux tarballs with `.sha256` files, and the signed remote-artifacts manifest to GitHub Releases; builds the static site last (its `prebuild` stages the Sparkle feed from the release just published).

Environment variables: `CODESIGN_IDENTITY`, `CODESIGN_CERTIFICATE_P12`, `CODESIGN_CERTIFICATE_PASSWORD`, `SPARKLE_PUBLIC_ED_KEY`, `SPARKLE_PRIVATE_ED_KEY`, `REMOTE_ARTIFACT_PUBLIC_ED25519_KEY`, `REMOTE_ARTIFACT_PRIVATE_ED25519_KEY`, `SPARKLE_FEED_URL`, `SPARKLE_DOWNLOAD_URL_PREFIX`, `NOTARIZE`, `APPLE_ID`, `TEAM_ID`, `APP_PASSWORD`, `GH_TOKEN`. For GitHub Actions, `CODESIGN_CERTIFICATE_P12` must be the base64-encoded Developer ID Application `.p12` matching `CODESIGN_IDENTITY`, and `CODESIGN_CERTIFICATE_PASSWORD` its export password.

Sparkle update hosting lives under `https://usespaces.dev/releases/` on the static Firebase site. Because a Hosting deploy replaces the whole site, GitHub release state is the source of truth: `scripts/stage-web-releases.sh` (run from `apps/web`'s `prebuild` on every build) stages two feeds. `releases/appcast.xml` is the stable feed (`releases/latest/download`, GitHub's newest non-prerelease); `releases/prerelease/appcast.xml` is the newest `v<major>.<minor>.<patch>` release regardless of prerelease flag. Both are served exactly as published (`publish-sparkle-appcast.sh` bakes the `https://usespaces.dev/releases` enclosure prefix in at signing time; nothing rewrites or re-signs an appcast at staging or promotion). Every website build republishes both feeds complete; a release that failed to publish its appcast/zip fails the next site build loudly. The staging script lists releases with `gh`, so a local `apps/web` build needs an authenticated `gh` and CI passes `GH_TOKEN`. The Linux installer is published the same way (copied to `https://usespaces.dev/install.sh` by the same `prebuild`, not a GitHub release asset). The app bundle carries `spaces`, `spacesd`, and Caddy in `Contents/Resources`; the DMG links `/usr/local/bin` and `~/.spaces/bin` to them so CLI, launchd, and remote-Mac pairing use the updated bundle after Sparkle updates; Linux artifacts link `~/.local/bin/spaces` to the managed `~/.spaces/bin/spaces` helper.

## Release Promotion

A tagged release starts as a GitHub prerelease and is promoted by hand once tested. There is one binary, one appcast, one artifact set per release; promotion changes only which feed serves it. Use the **`release-by-tag` skill** for the guided procedure.

1. Push a version tag. `release.yml` builds and creates the release with `--prerelease` (pinned via `--target`, never `--latest`), deploys the website from the tagged commit, and confirms the prerelease appcast serves the new version.
2. Test the prerelease.
3. Promote: edit the release and select **Latest** (`gh release edit <tag> --prerelease=false --latest`), which clears the prerelease flag and pins `releases/latest` in one update; the stable feed and `install.sh` resolve through that pin. The `released` event then runs [`release-promote.yml`](../.github/workflows/release-promote.yml), which checks out the release commit, confirms `releases/latest` resolves to the promoted tag before building, redeploys the website, and confirms the stable appcast serves the promoted version. Releases created by the Actions token do not raise `released`, so the tag build cannot trigger this workflow itself.

A prerelease that fails testing is left as a prerelease; the fix ships under the next patch tag, and a Mac that took the bad build moves to the fix on its next check automatically. `install.sh`'s no-version path resolves `releases/latest/download` (newest promoted release); its version-pinned form installs any release, promoted or not. Promotion never touches iOS: TestFlight is the iOS pre-release tier, and App Store submission is manual.

## iOS Release

[`.github/workflows/ios-release.yml`](../.github/workflows/ios-release.yml) builds the iOS app and uploads to App Store Connect for TestFlight. Pushing a version tag runs both the macOS and iOS release workflows, so both ship the same version; `workflow_dispatch` with a required `version` input cuts a TestFlight-only build from any branch without tagging a macOS release. Build number is `GITHUB_RUN_NUMBER` for both triggers.

The workflow obtains `GhosttyKit` the same way as macOS (`ensure_ghostty_artifacts.sh --publish-missing`, including iOS device/simulator slices), then `xcodebuild archive`/`-exportArchive` with [`apps/ios/ExportOptions.plist`](../apps/ios/ExportOptions.plist) (`method: app-store-connect`, `destination: upload`, the export step itself uploads to App Store Connect). The `.xcarchive` is retained as a workflow artifact. In `apps/ios/project.yml` the test targets are listed with `[test]` rather than `all` so `archive` (which needs `-enable-testing` for `@testable import` targets, a flag `Release` archiving does not set) does not try to compile them; XcodeGen regenerates the scheme from this, so hand-editing the generated `.xcscheme` does not stick.

Signing imports two long-lived certificates into a temporary keychain: one **Apple Distribution**, one **Apple Development**. `xcodebuild` still runs with `-allowProvisioningUpdates` and the App Store Connect API key to create/refresh *provisioning profiles* (uncapped), but finds both signing identities already present and mints no certificate. Both are needed because the archive phase signs automatically for development and `-exportArchive` re-signs for distribution. The certificates are stored rather than cloud-managed so a run never mints a fresh certificate against Apple's per-team certificate cap; the workflow's header comment has the full rationale.

Secrets: `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY_P8` (raw `.p8`, written to `$RUNNER_TEMP` with `600` perms for the build only), `IOS_CODESIGN_CERTIFICATE_P12`/`_PASSWORD` (Apple Distribution), `IOS_CODESIGN_DEV_CERTIFICATE_P12`/`_PASSWORD` (Apple Development).

To mint or renew either certificate: create it under [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list) (one Distribution, one Development), export it from Keychain Access as a `.p12` *with* its private key, set the matching secrets from `base64 -i <file>` and the export password. Apple issues these with one-year validity; renew before expiry and revoke a superseded certificate to keep the cap clear.

Three checks guard the arrangement (each catches a way a green release can silently leak a certificate): both identities must be present and usable (`security find-identity -v` lists valid ones only, so a `.p12` exported without its key or an expired certificate fails here by name); both certificates must belong to the signing team (read from the certificate's organizational unit, not common name, since a development certificate's parenthetical common-name suffix is per-certificate, not the team id); and the archive log must name an imported certificate as the signing identity, not one Apple names `Created via API` (which means `xcodebuild` minted a fresh one instead of using the imported pair).

The App Store Connect app record for `dev.usespaces.spacesmobile` must already exist before the first upload.

## Website Deploy

Firebase Hosting deploys from [`.github/workflows/firebase-hosting-merge.yml`](../.github/workflows/firebase-hosting-merge.yml) (pushes to `main` touching the site or the release staging script); [`firebase-hosting-pull-request.yml`](../.github/workflows/firebase-hosting-pull-request.yml) posts a PR preview channel. Release and promotion workflows deploy the same way, so every deploy republishes both Sparkle feeds from GitHub release state.

Deploys use `FirebaseExtended/action-hosting-deploy` against project `spaces-a1814`, authenticated with `FIREBASE_SERVICE_ACCOUNT_SPACES_A1814`; every workflow that builds `apps/web` passes `GH_TOKEN` (the site's `prebuild` reads GitHub releases with `gh`). `apps/web/firebase.json` is the only Hosting config (public directory, headers, app rewrite); every deploy runs with `entryPoint: apps/web`. The Hosting site's release storage limit is five versions (configured in the Firebase console under Hosting > Release history > release storage settings), which keeps stored versions (each carrying both staged Sparkle zips) well under quota.
