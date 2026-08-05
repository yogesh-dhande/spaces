#!/bin/bash
set -euo pipefail

# Drives deploy_linux_spacesd_e2e.sh's --profile validation without ever running a deploy.
#
# The script is copied into a throwaway tree that is a git repository (the deploy reads the repo's
# git-common-dir right after validation) but has no `.env`. Every name that clears validation
# therefore stops at the remote-host configuration check, long before anything builds, uploads, or
# reaches the remote account -- which is the only way to assert that a name was ACCEPTED without
# performing the deploy that acceptance leads to.
#
# Everything runs under a UTF-8 locale on purpose: bracket ranges in a bash `case` glob collate by
# locale, so 'A-Za-z' there also matches accented letters, and a non-ASCII name passed the very
# check written to reject it until the match was pinned to the C locale.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/spaces-deploy-profile-validation.XXXXXX")"
cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX

fail() {
    echo "deploy profile validation test failed: $*" >&2
    if [[ -f "$TMP_ROOT/out" ]]; then
        echo "--- last deploy output ---" >&2
        cat "$TMP_ROOT/out" >&2
    fi
    exit 1
}

TEMP_REPO="$TMP_ROOT/repo"
mkdir -p "$TEMP_REPO/apps/macos/scripts" "$TEMP_REPO/scripts"
cp "$APP_ROOT/scripts/deploy_linux_spacesd_e2e.sh" "$TEMP_REPO/apps/macos/scripts/"
cp "$REPO_ROOT/scripts/spaces-e2e-env.sh" "$TEMP_REPO/scripts/"
chmod +x "$TEMP_REPO/apps/macos/scripts/deploy_linux_spacesd_e2e.sh"
git -C "$TEMP_REPO" init -q

run_deploy() {
    set +e
    env LC_ALL=en_US.UTF-8 "$TEMP_REPO/apps/macos/scripts/deploy_linux_spacesd_e2e.sh" "$@" >"$TMP_ROOT/out" 2>&1
    local status=$?
    set -e
    printf '%s' "$status"
}

output_has() {
    grep -q "$1" "$TMP_ROOT/out"
}

# The installed profile is the lane real paired clients talk to, and it carries release builds only.
# A source deploy there is refused outright, before anything remote runs.
status="$(run_deploy --profile installed)"
[[ "$status" -eq 1 ]] || fail "--profile installed exited $status instead of 1"
output_has "refuses --profile installed" || fail "--profile installed was not refused by name"
output_has "installed profile is the lane paired clients talk to" || fail "the refusal does not say what the installed lane is"
if output_has "required env file was not found"; then
    fail "--profile installed reached remote configuration instead of stopping at validation"
fi

status="$(run_deploy --profile café)"
[[ "$status" -eq 1 ]] || fail "a non-ASCII profile name exited $status instead of 1"
output_has "is not a valid profile name" || fail "a non-ASCII profile name was not rejected by the charset check"

status="$(run_deploy --profile ..)"
[[ "$status" -eq 1 ]] || fail "a traversal profile name exited $status instead of 1"
output_has "is not a valid profile name" || fail "a traversal profile name was not rejected by the charset check"

# A development profile name clears validation and the deploy proceeds; in this tree it can get no
# further than the missing remote configuration, which is exactly how far acceptance can be observed
# without deploying.
status="$(run_deploy --profile remote-mobile-demo)"
[[ "$status" -eq 1 ]] || fail "a development profile name exited $status instead of 1"
output_has "required env file was not found" || fail "a development profile name did not proceed past validation to remote configuration"
if output_has "refuses --profile installed"; then
    fail "a development profile name hit the installed-lane refusal"
fi
if output_has "is not a valid profile name"; then
    fail "a development profile name was rejected by the charset check"
fi

echo "deploy profile validation tests passed"
