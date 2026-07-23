#!/bin/sh
set -eu

# impacted_tests.sh — run only the macOS SwiftPM test targets affected by the
# working tree's changes vs origin/main. Inner-dev-loop speed-up only; see
# "NOT THE COMMIT GATE" below.
#
# CHANGED PATHS
#   `git diff --name-only --merge-base origin/main` diffs the merge base of
#   origin/main and HEAD against the *working tree* in one command, so it
#   already includes staged and unstaged edits to tracked files alongside
#   committed branch history. It never reports untracked files, so we union
#   it with `git status --porcelain --untracked-files=all` (the `=all` mode
#   matters: the default `normal` mode collapses a brand-new untracked
#   directory into one line instead of listing the files inside it, which
#   would hide a new test file from the target mapper below). Renamed-but-
#   uncommitted files are read from the porcelain `old -> new` form and both
#   sides are counted as changed; a rename already committed on the branch
#   only shows its new path (`git diff --name-only` doesn't report the old
#   side of a rename), which is an accepted minor gap, not a fallback path.
#   If origin/main can't be resolved, this script fails loudly — it does not
#   guess another base ref.
#
# TARGET MAPPING AND REVERSE CLOSURE
#   `xcrun swift package describe --type json`, run directly (not through
#   scripts/swiftpm.sh), gives the declared `path` and `target_dependencies`
#   for every target. It's read-only: verified by hand (2026-07-22) that a
#   plain invocation completes in under a second and touches no file under
#   .build/, so it doesn't need scripts/swiftpm.sh's exec lock. Each changed
#   path under Sources/ or Tests/ is mapped to the target whose declared
#   `path` prefixes it (not a hardcoded "Sources/<name>" guess, so it stays
#   correct if a target ever declares a custom `path:`). A test target is
#   impacted if it was changed directly, or if the transitive closure of its
#   `target_dependencies` intersects the set of changed non-test targets.
#
# CONSERVATIVE ESCAPE HATCH
#   A changed path under apps/macos/ that is not under Sources/ or Tests/
#   (Package.swift, Package.resolved, scripts/, anything else at the package
#   root) can change the build graph, toolchain inputs, or test tooling
#   itself, so it runs the full suite rather than trying to be clever. A
#   changed path under Sources/ or Tests/ that doesn't match any target's
#   declared path (package graph stale vs. the change) does the same. Paths
#   entirely outside apps/macos (docs/, apps/web/, apps/ios/, ...) map to no
#   macOS target; if that leaves nothing impacted, this script says so and
#   exits 0 without running any tests.
#
# --filter AND MIXED TEST FRAMEWORKS
#   Investigated against SwiftPM's and swift-testing's own sources
#   (swiftlang/swift-package-manager Sources/Commands/SwiftTestCommand.swift,
#   swiftlang/swift-testing Sources/Testing/Test.ID.swift +
#   Running/Configuration.TestFilter.swift). For XCTest, `--filter` regex-
#   matches each test's "specifier" string, formatted "ModuleName.Class/test".
#   For Swift Testing, `--filter` is forwarded verbatim to the swift-testing
#   runtime's own `--filter`, which regex-searches `String(describing:
#   test.id)` — and `Test.ID.description` says explicitly it "match[es] the
#   'specifier' format used by `swift test` with XCTest": "ModuleName." followed
#   by the rest. Both frameworks therefore key their identifier on the
#   SwiftPM module (= target) name at the front, so one anchored alternation
#   regex reliably selects whole targets in both frameworks at once — no
#   per-framework fallback is needed:
#     scripts/swiftpm.sh test --filter '^(TargetA|TargetB)\.'
#
# BUILD IS ALWAYS FULL
#   All macOS test targets link into one merged xctest bundle
#   (spacesPackageTests.xctest). `swift build --build-tests` (which `swift
#   test` runs first) always compiles every declared target regardless of
#   --filter — there is no way to build only the impacted subset. This
#   script can only reduce which already-built tests *execute*, so it saves
#   run time, not build time.
#
# NOT THE COMMIT GATE
#   scripts/verify.sh (full build, lint, and test) remains the required gate
#   before committing. This script is for the inner dev loop only.

root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(cd "$root/../.." && pwd)"

if ! git -C "$repo_root" rev-parse --verify --quiet origin/main >/dev/null; then
    echo "impacted_tests.sh: origin/main is not available in this checkout (git rev-parse --verify origin/main failed)." >&2
    echo "Fetch it, e.g. 'git fetch origin main', and retry. This script will not guess another base ref." >&2
    exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/spaces-impacted-tests.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT INT TERM HUP

changed_paths_file="$work_dir/changed-paths.txt"
{
    git -C "$repo_root" diff --name-only --merge-base origin/main
    git -C "$repo_root" status --porcelain --untracked-files=all | cut -c4- |
        awk '{ n = index($0, " -> "); if (n > 0) { print substr($0, 1, n - 1); print substr($0, n + 4) } else { print } }'
} | sort -u >"$changed_paths_file"

if [ ! -s "$changed_paths_file" ]; then
    echo "impacted_tests.sh: no changed paths vs origin/main; nothing to test."
    exit 0
fi

echo "Changed paths vs origin/main (including uncommitted work):"
sed 's/^/  /' "$changed_paths_file"

select_script="$work_dir/select.py"
cat >"$select_script" <<'PY'
# Maps changed paths to SwiftPM targets, computes the reverse dependency
# closure, and prints one of three machine-readable outcomes on stdout for
# the calling shell script to act on (human-readable explanation goes to
# stderr so it streams straight to the terminal):
#   FULL              - run the whole suite (escape hatch or stale-graph path)
#   NONE              - nothing impacted, run nothing
#   TARGETS\n<name>*  - run exactly these test targets
import json
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])  # apps/macos
changed_paths_file = Path(sys.argv[2])

MACOS_PREFIX = "apps/macos/"

changed = [line.strip() for line in changed_paths_file.read_text().splitlines() if line.strip()]

escape_hatch_paths = []
mapped_relative_paths = []  # under Sources/ or Tests/, relative to apps/macos/
outside_macos_count = 0

for path in changed:
    if not path.startswith(MACOS_PREFIX):
        outside_macos_count += 1
        continue
    rel = path[len(MACOS_PREFIX):]
    if rel.startswith("Sources/") or rel.startswith("Tests/"):
        mapped_relative_paths.append(rel)
    else:
        escape_hatch_paths.append(path)

if escape_hatch_paths:
    print(
        "Changed path(s) under apps/macos/ outside Sources/ and Tests/ can change the "
        "build graph or test tooling itself, so the full suite runs:",
        file=sys.stderr,
    )
    for p in escape_hatch_paths:
        print(f"  {p}", file=sys.stderr)
    print("FULL")
    sys.exit(0)

if not mapped_relative_paths:
    if outside_macos_count:
        print(
            f"{outside_macos_count} changed path(s) are outside apps/macos/; none map to a "
            "macOS SwiftPM test target.",
            file=sys.stderr,
        )
    else:
        print("No changed paths map to a macOS SwiftPM test target.", file=sys.stderr)
    print("NONE")
    sys.exit(0)

# Read-only: verified by hand that this completes in well under a second and
# writes nothing under .build/, so it doesn't need scripts/swiftpm.sh's lock.
describe = subprocess.run(
    ["xcrun", "swift", "package", "describe", "--type", "json"],
    cwd=root,
    capture_output=True,
    text=True,
    check=True,
)
graph = json.loads(describe.stdout)
targets = {t["name"]: t for t in graph["targets"]}


def target_for_path(rel_path):
    # Longest-prefix match against each target's declared `path` (e.g.
    # "Sources/spacesterminalcore" or "Tests/workspacecoreTests") rather than
    # assuming "Sources/<name>", so this stays correct even if a target ever
    # declares a non-default `path:` in Package.swift.
    best_name = None
    best_path = ""
    for name, t in targets.items():
        p = t.get("path")
        if not p:
            continue
        if rel_path == p or rel_path.startswith(p + "/"):
            if len(p) > len(best_path):
                best_name, best_path = name, p
    return best_name


changed_target_names = set()
unmapped_paths = []
for rel_path in mapped_relative_paths:
    name = target_for_path(rel_path)
    if name is None:
        unmapped_paths.append(rel_path)
    else:
        changed_target_names.add(name)

if unmapped_paths:
    print(
        "Changed path(s) under Sources/ or Tests/ don't match any declared SwiftPM "
        "target path (package graph may be stale vs. this change), so the full suite runs:",
        file=sys.stderr,
    )
    for p in unmapped_paths:
        print(f"  {MACOS_PREFIX}{p}", file=sys.stderr)
    print("FULL")
    sys.exit(0)

test_target_names = {name for name, t in targets.items() if t.get("type") == "test"}
directly_changed_test_targets = changed_target_names & test_target_names
changed_source_targets = changed_target_names - test_target_names


def transitive_deps(name, memo):
    if name in memo:
        return memo[name]
    memo[name] = {name}  # cycle guard; corrected below once fully computed
    result = {name}
    for dep in targets.get(name, {}).get("target_dependencies", []):
        result |= transitive_deps(dep, memo)
    memo[name] = result
    return result


memo = {}
impacted = set(directly_changed_test_targets)
for tt in sorted(test_target_names):
    deps = transitive_deps(tt, memo) - {tt}
    if deps & changed_source_targets:
        impacted.add(tt)

if not impacted:
    print(
        "Changed source target(s) "
        + ", ".join(sorted(changed_source_targets))
        + " have no test target depending on them.",
        file=sys.stderr,
    )
    print("NONE")
    sys.exit(0)

print("Changed source target(s): " + (", ".join(sorted(changed_source_targets)) or "(none)"), file=sys.stderr)
print(
    "Directly changed test target(s): " + (", ".join(sorted(directly_changed_test_targets)) or "(none)"),
    file=sys.stderr,
)
print("TARGETS")
for name in sorted(impacted):
    print(name)
PY

selection_output="$(python3 "$select_script" "$root" "$changed_paths_file")"
action="$(printf '%s\n' "$selection_output" | head -n 1)"

case "$action" in
    FULL)
        echo "Running the full macOS SwiftPM test suite via scripts/swiftpm.sh."
        "$root/scripts/swiftpm.sh" test
        ;;
    NONE)
        echo "impacted_tests.sh: nothing impacted; skipping tests."
        exit 0
        ;;
    TARGETS)
        impacted_targets="$(printf '%s\n' "$selection_output" | tail -n +2)"
        filter="^($(printf '%s\n' "$impacted_targets" | paste -sd'|' -))\\."
        echo "Impacted test target(s):"
        printf '%s\n' "$impacted_targets" | sed 's/^/  /'
        echo "Running: scripts/swiftpm.sh test --filter '$filter'"
        "$root/scripts/swiftpm.sh" test --filter "$filter"
        ;;
    *)
        echo "impacted_tests.sh: internal error: unrecognized selection output from the embedded selector" >&2
        printf '%s\n' "$selection_output" >&2
        exit 1
        ;;
esac
