#!/bin/sh
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/scripts/silence-watchdog.sh"
start_epoch="$(date +%s)"
cache_dir="$root/.build/clang-module-cache"
coverage_dir="$root/.build/coverage"
# Coverage builds get a scratch path of their own, never the shared .build that holds the product
# executables. `--enable-code-coverage` instruments every target it builds, executables included, and
# an instrumented binary with no LLVM_PROFILE_FILE writes a default.profraw into whatever directory
# it was run from -- so instrumenting the shared .build/debug binaries left every later `spaces`,
# `spacesd`, or `SpacesApp` invocation dropping profile dumps around the machine. One of the places
# they landed was the Ghostty submodule, where the Linux artifact build's clean-tree check failed on
# a file the host's global excludes made invisible. A separate scratch path also keeps the two builds
# from invalidating each other: toggling the coverage flag in one scratch tree recompiles the whole
# package, so a plain build followed by a coverage build used to pay for both from scratch. It is
# persistent, so both trees stay incremental across runs.
coverage_scratch_path="$root/.build/coverage-scratch"
test_config_home="$root/.build/test-config-home"
test_log_path="$coverage_dir/swift-test.log"
test_status_path="$coverage_dir/swift-test-status"
mkdir -p "$cache_dir"
mkdir -p "$coverage_dir"
rm -rf "$test_config_home"
mkdir -p "$test_config_home"
rm -f "$test_log_path" "$test_status_path"
export CLANG_MODULE_CACHE_PATH="$cache_dir"
export XDG_CONFIG_HOME="$test_config_home"
export MOCK_TEST_DELAY_CAP_MS="${MOCK_TEST_DELAY_CAP_MS:-25}"

if [ "${SPACES_TEST_SKIP_BUILD:-0}" = "1" ]; then
    echo "SPACES_TEST_SKIP_BUILD is not supported; SwiftPM coverage requires its build phase to prepare codecov artifacts." >&2
    exit 1
fi

unset SPACES_DEVICE_API_PORT

codecov_json_path="$("$root/scripts/swiftpm.sh" test --show-codecov-path --scratch-path "$coverage_scratch_path")"
codecov_dir="$(dirname "$codecov_json_path")"
profdata_path="$codecov_dir/default.profdata"
mkdir -p "$codecov_dir"
rm -f "$codecov_json_path" "$profdata_path" "$codecov_dir"/*.profraw

report_elapsed_time() {
    end_epoch="$(date +%s)"
    elapsed_seconds=$((end_epoch - start_epoch))
    echo "Coverage script elapsed: ${elapsed_seconds}s"
}
trap report_elapsed_time EXIT

generate_codecov_artifacts() {
    mkdir -p "$codecov_dir"
    profraw_count="$(find "$codecov_dir" -maxdepth 1 -type f -name '*.profraw' | wc -l | tr -d ' ')"
    if [ "$profraw_count" = "0" ]; then
        echo "Coverage raw profiles not found in SwiftPM codecov directory: $codecov_dir" >&2
        exit 1
    fi

    test_binary="$(cd "$codecov_dir/.." && pwd)/spacesPackageTests.xctest/Contents/MacOS/spacesPackageTests"
    if [ ! -x "$test_binary" ]; then
        echo "Coverage test binary not found: $test_binary" >&2
        exit 1
    fi

    echo "Generating coverage artifacts from $profraw_count raw profile files..."
    find "$codecov_dir" -maxdepth 1 -type f -name '*.profraw' -print0 |
        xargs -0 xcrun llvm-profdata merge -sparse -o "$profdata_path"
    xcrun llvm-cov export -format=text -instr-profile "$profdata_path" "$test_binary" >"$codecov_json_path"
}

# Decides whether a non-zero `swift test` exit can be attributed to SwiftPM's post-test steps
# rather than to the tests themselves, which is the only case the caller forgives.
#
# A crashed test process is NOT such a case, and it announces itself differently from a failed
# assertion: the worker dies mid-test, so it never prints the `Test Case ... failed` or `: error: -[`
# line a normal failure would, while the swift-testing lane can still report its own suites passing.
# Matching only the failure markers therefore forgave a crash and reported the run green -- the exact
# shape of the CI-only SIGTRAP that killed test workers in this suite. Treat the runtime's crash
# announcements as disqualifying too.
test_log_reports_success() {
    python3 - "$test_log_path" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.is_file():
    raise SystemExit(1)

text = path.read_text(errors="replace")
swift_testing_passed = re.search(r"Test run with \d+ tests in \d+ suites passed after", text) is not None
xctest_failed = (
    re.search(r"Test (Suite|Case) '.*' failed", text) is not None
    or re.search(r": error: -\[", text) is not None
)
test_process_crashed = (
    re.search(r"error: Exited with unexpected signal code \d+", text) is not None
    or re.search(r"^.*: Fatal error:", text, re.MULTILINE) is not None
)

raise SystemExit(0 if swift_testing_passed and not xctest_failed and not test_process_crashed else 1)
PY
}

echo "Building SwiftPM tests with coverage..."
# This is the only build of the coverage scratch tree, so it is a full compile the first time and
# incremental afterwards. verify.sh's own build produces the uninstrumented product binaries in the
# shared .build and never touches this tree.
"$root/scripts/swiftpm.sh" build --build-tests --enable-code-coverage --scratch-path "$coverage_scratch_path"

echo "Running SwiftPM coverage tests..."
# The mirror-surface suites (GhosttyMirrorGraphemeClusterTests, GhosttyMirrorLinkActivationTests,
# GhosttyMirrorSurfaceMRUTests, GhosttyMirrorSurfacePresentationTests) drive a REAL mirror-owned
# ghostty app, and only one embedded ghostty app may be live per process
# (GhosttyProcessAppRuntime.initializeOnce). Every test class in the package shares one
# spacesPackageTests bundle, so a parallel worker process that ran any daemon-core suite first
# cannot host the mirror app afterwards — worker assignment is arbitrary, which makes these suites
# crash their worker only in full runs and take innocent tests down with the redistribution. They
# are skipped here and run together in their own process below.
set -- test --skip-build --enable-code-coverage --disable-sandbox --scratch-path "$coverage_scratch_path" \
    --skip GhosttyMirrorGraphemeClusterTests --skip GhosttyMirrorLinkActivationTests --skip GhosttyMirrorSurfaceMRUTests \
    --skip GhosttyMirrorSurfacePresentationTests
if [ "${SPACES_TEST_PARALLEL:-1}" = "1" ]; then
    workers="${SPACES_TEST_WORKERS:-}"
    # Auto worker count is uncapped by default: measured on a 14-core machine, capping at 8
    # cost 37% of the test run's wall time (56.5s vs 35.4s). SPACES_TEST_MAX_AUTO_WORKERS
    # remains available to impose a ceiling.
    max_auto_workers="${SPACES_TEST_MAX_AUTO_WORKERS:-0}"
    if [ -z "$workers" ]; then
        detected_workers="$(sysctl -n hw.logicalcpu 2>/dev/null || echo "")"
        case "$detected_workers" in
            ''|*[!0-9]*)
                workers=""
                ;;
            *)
                workers="$detected_workers"
                case "$max_auto_workers" in
                    ''|*[!0-9]*)
                        ;;
                    *)
                        if [ "$max_auto_workers" -gt 0 ] && [ "$workers" -gt "$max_auto_workers" ]; then
                            workers="$max_auto_workers"
                        fi
                        ;;
                esac
                ;;
        esac
    fi

    set -- "$@" --parallel
    if [ -n "$workers" ]; then
        echo "Using parallel test workers: $workers"
        if [ -n "${detected_workers:-}" ] && [ "$workers" != "${detected_workers:-}" ]; then
            echo "Auto worker count capped from $detected_workers to $workers"
        fi
        set -- "$@" --num-workers "$workers"
    fi
else
    echo "Using serial coverage tests. Set SPACES_TEST_PARALLEL=1 to opt back into parallel coverage."
fi

set +e
(
    run_with_silence_watchdog "${SPACES_VERIFY_STALL_SECONDS:-600}" "$root/scripts/swiftpm.sh" "$@"
    printf '%s\n' "$?" >"$test_status_path"
) 2>&1 | tee "$test_log_path"
tee_status="$?"
set -e

if [ "$tee_status" -ne 0 ]; then
    exit "$tee_status"
fi
if [ ! -f "$test_status_path" ]; then
    echo "SwiftPM coverage test command did not record an exit status." >&2
    exit 1
fi

swiftpm_status="$(cat "$test_status_path")"
if [ "$swiftpm_status" -ne 0 ]; then
    if test_log_reports_success; then
        echo "SwiftPM coverage test command exited with status $swiftpm_status after a passing test run; generating coverage artifacts from raw profiles."
    else
        exit "$swiftpm_status"
    fi
fi

# The mirror-surface suites skipped above, in a process of their own so the mirror service is the
# process's one embedded ghostty app. Serial and filtered: fresh process, same coverage scratch so
# their raw profiles merge into the artifacts generated below.
#
# Not on CI runners: these suites need a real rendering ghostty surface to export a frame, and the
# GitHub macOS runner never produces one — they time out at SurfaceSnapshotTimeout even in this
# dedicated serial process, with the runner consuming artifacts byte-identical (object md5 and
# resources) to ones that pass on developer machines, so the difference is the runner environment,
# not the build. Local verify remains their gate, like the desktop e2e lanes.
if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "SKIPPING mirror-surface coverage tests: CI runners cannot host a rendering ghostty surface (gated by local verify)."
else
    echo "Running mirror-surface coverage tests in their own process..."
    run_with_silence_watchdog "${SPACES_VERIFY_STALL_SECONDS:-600}" "$root/scripts/swiftpm.sh" test --skip-build --enable-code-coverage \
        --disable-sandbox --scratch-path "$coverage_scratch_path" \
        --filter "GhosttyMirrorGraphemeClusterTests|GhosttyMirrorLinkActivationTests|GhosttyMirrorSurfaceMRUTests|GhosttyMirrorSurfacePresentationTests"
fi

generate_codecov_artifacts
if [ ! -f "$codecov_json_path" ]; then
    echo "Coverage JSON not found at SwiftPM-reported path: $codecov_json_path" >&2
    exit 1
fi

if [ ! -f "$profdata_path" ]; then
    echo "Coverage profdata not found next to SwiftPM coverage JSON: $profdata_path" >&2
    exit 1
fi

report_path="$coverage_dir/coverage-summary.txt"

echo "Coverage report:"
python3 - "$root" "$codecov_json_path" "$report_path" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
codecov_json_path = Path(sys.argv[2]).resolve()
report_path = Path(sys.argv[3]).resolve()

payload = json.loads(codecov_json_path.read_text())
data = payload["data"][0]
files = data["files"]
totals = data["totals"]

module_order = [
    "workspacecore",
    "spacesui",
    "systembridge",
    "spacescli",
    "spaces",
    "SpacesApp",
    "spacese2e",
]
module_totals = {
    module: {
        "lines": {"count": 0, "covered": 0},
        "regions": {"count": 0, "covered": 0},
        "functions": {"count": 0, "covered": 0},
    }
    for module in module_order
}
source_rows = []

for file_entry in files:
    filename = Path(file_entry["filename"]).resolve()
    try:
        relative = filename.relative_to(root)
    except ValueError:
        continue
    parts = relative.parts
    if len(parts) < 3 or parts[0] != "Sources":
        continue

    module = parts[1]
    if module not in module_totals:
        continue

    summary = file_entry["summary"]
    for metric in ("lines", "regions", "functions"):
        module_totals[module][metric]["count"] += summary[metric]["count"]
        module_totals[module][metric]["covered"] += summary[metric]["covered"]

    source_rows.append(
        (
            module,
            str(relative),
            summary["lines"]["covered"],
            summary["lines"]["count"],
            summary["lines"]["percent"],
        )
    )

def format_percent(covered: int, count: int) -> str:
    if count == 0:
        return "0.00%"
    return f"{covered * 100 / count:.2f}%"

lines = []
lines.append("Coverage summary:")
lines.append(f"  overall lines: {totals['lines']['percent']:.2f}%")
lines.append(f"  overall regions: {totals['regions']['percent']:.2f}%")
lines.append(f"  overall functions: {totals['functions']['percent']:.2f}%")
for module in module_order:
    module_summary = module_totals[module]
    if module_summary["lines"]["count"] == 0:
        continue
    lines.append(
        "  "
        + f"{module}: lines {format_percent(module_summary['lines']['covered'], module_summary['lines']['count'])}"
        + f" | regions {format_percent(module_summary['regions']['covered'], module_summary['regions']['count'])}"
        + f" | functions {format_percent(module_summary['functions']['covered'], module_summary['functions']['count'])}"
    )

lines.append("")
lines.append("Source files:")
for module, relative, covered, count, percent in sorted(source_rows):
    lines.append(f"  {module}: {percent:.2f}% ({covered}/{count}) {relative}")

report_path.write_text("\n".join(lines) + "\n")
print("\n".join(lines))
PY

echo "Coverage report saved to: $report_path"
