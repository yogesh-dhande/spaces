#!/bin/bash
# Regression test (#599): the release DMG step retries hdiutil resource contention ("Resource
# busy") but fails at once on a deterministic error such as "No space left on device".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/spaces-release-helpers.sh"

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/spaces-create-dmg-retry-test.XXXXXX")"
trap 'rm -rf "$WORK_ROOT"' EXIT

fail() {
    echo "create dmg retry test failed: $*" >&2
    exit 1
}

staging="$WORK_ROOT/staging"
mkdir -p "$staging"
echo "ordinary file" > "$staging/ordinary.txt"

stub_dir="$WORK_ROOT/bin"
mkdir -p "$stub_dir"
calls_file="$WORK_ROOT/calls"

# Writes a stub hdiutil. $1 is the stderr line of the injected failure; $2 is "once" to fail only the
# first call and then delegate to the real hdiutil, or "always" to fail every call.
write_stub() {
    cat > "$stub_dir/hdiutil" <<EOF
#!/bin/bash
echo call >> "$calls_file"
calls=\$(wc -l < "$calls_file")
if [[ "$2" == always || \$calls -eq 1 ]]; then
    echo "$1" >&2
    exit 1
fi
exec /usr/bin/hdiutil "\$@"
EOF
    chmod +x "$stub_dir/hdiutil"
    : > "$calls_file"
}

call_count() {
    wc -l < "$calls_file" | tr -d ' '
}

# Case 1: contention on the first attempt is retried and the DMG ends up valid.
write_stub "hdiutil: create failed - Resource busy" once
dmg_path="$WORK_ROOT/retry.dmg"
PATH="$stub_dir:$PATH" spaces_release_create_dmg "$staging" "Spaces-dmg-retry-test" "$dmg_path" >/dev/null \
    || fail "DMG creation did not recover from a Resource busy failure"
# At least 2: the real hdiutil behind the stub can hit contention of its own, which the helper also retries.
(( $(call_count) >= 2 )) || fail "expected a retry after one contention failure, got $(call_count) hdiutil calls"
/usr/bin/hdiutil verify "$dmg_path" >/dev/null || fail "retried DMG did not verify"

# Case 2: a deterministic failure is not retried.
write_stub "hdiutil: create failed - No space left on device" always
if PATH="$stub_dir:$PATH" spaces_release_create_dmg "$staging" "Spaces-dmg-retry-test" "$WORK_ROOT/fail.dmg" >/dev/null 2>&1; then
    fail "DMG creation succeeded despite a No space left on device failure"
fi
[[ "$(call_count)" == 1 ]] || fail "expected exactly 1 hdiutil call for a deterministic failure, got $(call_count)"

echo "create dmg retry test passed"
