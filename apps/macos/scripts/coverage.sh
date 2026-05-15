#!/bin/sh
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
start_epoch="$(date +%s)"
cache_dir="$root/.build/clang-module-cache"
coverage_dir="$root/.build/coverage"
mkdir -p "$cache_dir"
mkdir -p "$coverage_dir"
export CLANG_MODULE_CACHE_PATH="$cache_dir"
export MOCK_TEST_DELAY_CAP_MS="${MOCK_TEST_DELAY_CAP_MS:-25}"

report_elapsed_time() {
    end_epoch="$(date +%s)"
    elapsed_seconds=$((end_epoch - start_epoch))
    echo "Coverage script elapsed: ${elapsed_seconds}s"
}
trap report_elapsed_time EXIT

echo "Running swift test with coverage..."
workers="${SPACES_TEST_WORKERS:-}"
max_auto_workers="${SPACES_TEST_MAX_AUTO_WORKERS:-8}"
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

set -- test --parallel --enable-code-coverage --disable-sandbox
if [ -n "$workers" ]; then
    echo "Using parallel test workers: $workers"
    if [ -n "${detected_workers:-}" ] && [ "$workers" != "${detected_workers:-}" ]; then
        echo "Auto worker count capped from $detected_workers to $workers"
    fi
    set -- "$@" --num-workers "$workers"
fi
if [ "${SPACES_TEST_SKIP_BUILD:-0}" = "1" ]; then
    echo "Skipping rebuild before tests (SPACES_TEST_SKIP_BUILD=1)"
    set -- "$@" --skip-build
fi

"$root/scripts/swiftpm.sh" "$@"

codecov_json_path="$("$root/scripts/swiftpm.sh" test --show-codecov-path)"
if [ ! -f "$codecov_json_path" ]; then
    echo "Coverage JSON not found at SwiftPM-reported path: $codecov_json_path" >&2
    exit 1
fi

codecov_dir="$(dirname "$codecov_json_path")"
profdata_path="$codecov_dir/default.profdata"
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
