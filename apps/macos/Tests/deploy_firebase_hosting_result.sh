#!/bin/bash
set -euo pipefail

# Drives scripts/deploy-firebase-hosting.sh against a stubbed firebase-tools and proves the only
# thing that script decides: which `firebase deploy --json` results are a failure.
#
# This is the whole point of running the CLI on the three live-channel deploys instead of
# FirebaseExtended/action-hosting-deploy: the action fails its step on a deploy error, but the
# `continue-on-error: true` those workflows set to tolerate the HTTP 400 no-op also hid every real
# error, including a Hosting storage quota HTTP 429 that would pass as a green deploy step and
# leave a release half-shipped. The one result that is genuinely not a failure -- HTTP 400 "is the
# current active version", meaning the built site is byte-identical to the live one -- has to keep
# passing, or every release that does not change the website fails.
#
# Nothing here deploys: `npx` is a stub that records how it was invoked and prints a canned result.
# It also records the credentials file it was handed, so the test can assert the service account
# JSON reaches the CLI as a file and that the file is gone once the script exits.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
SOURCE_DEPLOY_SCRIPT="$REPO_ROOT/scripts/deploy-firebase-hosting.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/spaces-deploy-firebase-hosting.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
# TMPDIR carries a trailing slash on macOS, so the path mktemp prints holds a doubled separator.
# Normalize it here, or the working-directory assertion below compares two spellings of the same
# directory: the script deploys the apps/web of whatever path the test hands it as a working
# directory.
TMP_ROOT="$(cd "$TMP_ROOT" && pwd)"

CURRENT_OUT=""
fail() {
    echo "deploy-firebase-hosting result test failed: $*" >&2
    if [[ -n "$CURRENT_OUT" && -f "$CURRENT_OUT" ]]; then
        echo "--- last deploy output ---" >&2
        cat "$CURRENT_OUT" >&2
    fi
    exit 1
}

# The script deploys the apps/web of the directory it is run from, so the checkout's own copy of
# the script is run against a throwaway tree standing in for a deployable checkout -- exactly the
# shape promotion uses, where main's copy of the script runs against a released commit's checkout.
# The stub never reads the site, so an empty apps/web carrying a firebase.json is site enough.
TEMP_REPO="$TMP_ROOT/repo"
STUB_BIN="$TMP_ROOT/bin"
mkdir -p "$TEMP_REPO/apps/web" "$STUB_BIN"
printf '{"hosting":{"public":"out"}}\n' > "$TEMP_REPO/apps/web/firebase.json"

# Derived from the script under test so pinning a different firebase-tools release does not turn
# this into a failing assertion about a version nobody changed on purpose.
FIREBASE_TOOLS_VERSION="$(sed -n 's/^FIREBASE_TOOLS_VERSION="\(.*\)"$/\1/p' "$SOURCE_DEPLOY_SCRIPT" | head -n 1)"
PROJECT_ID="$(sed -n 's/^PROJECT_ID="\(.*\)"$/\1/p' "$SOURCE_DEPLOY_SCRIPT" | head -n 1)"
[[ -n "$FIREBASE_TOOLS_VERSION" ]] || fail "could not read FIREBASE_TOOLS_VERSION from deploy-firebase-hosting.sh"
[[ -n "$PROJECT_ID" ]] || fail "could not read PROJECT_ID from deploy-firebase-hosting.sh"

SERVICE_ACCOUNT_JSON='{"type":"service_account","project_id":"spaces-a1814","private_key":"stub"}'

cat > "$STUB_BIN/npx" <<'EOF'
#!/bin/bash
set -euo pipefail

{
    printf 'pwd=%s\n' "$PWD"
    printf 'argv=%s\n' "$*"
    printf 'credentials_path=%s\n' "${GOOGLE_APPLICATION_CREDENTIALS:-}"
    if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" && -f "$GOOGLE_APPLICATION_CREDENTIALS" ]]; then
        printf 'credentials_contents=%s\n' "$(cat "$GOOGLE_APPLICATION_CREDENTIALS")"
    fi
} > "$SPACES_TEST_NPX_LOG"

cat "$SPACES_TEST_DEPLOY_RESULT"
exit "$SPACES_TEST_DEPLOY_EXIT"
EOF
chmod +x "$STUB_BIN/npx"

NPX_LOG="$TMP_ROOT/npx.log"
DEPLOY_RESULT="$TMP_ROOT/result.json"

# Runs the script with the given canned firebase-tools result, from the given working directory,
# and returns its exit status. Every case but the missing-site one runs from the temp repo, which
# stands in for the checkout whose site is being deployed.
run_deploy() {
    local label="$1" result_json="$2" deploy_exit="$3" service_account="$4" work_dir="${5:-$TEMP_REPO}"
    CURRENT_OUT="$TMP_ROOT/$label.out"

    : > "$NPX_LOG"
    printf '%s\n' "$result_json" > "$DEPLOY_RESULT"

    local status=0
    (cd "$work_dir" && env \
        "PATH=$STUB_BIN:$PATH" \
        "FIREBASE_SERVICE_ACCOUNT=$service_account" \
        "SPACES_TEST_NPX_LOG=$NPX_LOG" \
        "SPACES_TEST_DEPLOY_RESULT=$DEPLOY_RESULT" \
        "SPACES_TEST_DEPLOY_EXIT=$deploy_exit" \
        "$SOURCE_DEPLOY_SCRIPT") \
        > "$CURRENT_OUT" 2>&1 || status=$?
    return "$status"
}

logged() {
    grep -qF "$1" "$NPX_LOG"
}

# 1. A successful deploy passes, and the CLI is invoked the way the workflows depend on: the pinned
#    firebase-tools release, the live channel of the Spaces project, from apps/web, with the
#    service account handed over as a credentials file rather than on the command line. The
#    apps/web it deploys is the one under the directory it was run from, not one beside the script.
run_deploy "success" '{"status":"success","result":{"hosting":"sites/spaces-a1814/versions/abc123"}}' 0 "$SERVICE_ACCOUNT_JSON" \
    || fail "a successful deploy did not exit 0"
grep -q "sites/spaces-a1814/versions/abc123" "$CURRENT_OUT" \
    || fail "a successful deploy did not report the deployed version"
logged "firebase-tools@$FIREBASE_TOOLS_VERSION deploy --only hosting --project $PROJECT_ID --non-interactive --json" \
    || fail "firebase-tools was not invoked with the pinned version and live-channel deploy arguments"
logged "pwd=$TEMP_REPO/apps/web" \
    || fail "the deploy did not run from the apps/web of the directory the script was run from"
logged "credentials_contents=$SERVICE_ACCOUNT_JSON" \
    || fail "GOOGLE_APPLICATION_CREDENTIALS did not point at a file holding the service account JSON"

# The credentials file is removed when the script exits, so the JSON never outlives the deploy.
credentials_path="$(sed -n 's/^credentials_path=//p' "$NPX_LOG")"
[[ -n "$credentials_path" ]] || fail "the stub recorded no GOOGLE_APPLICATION_CREDENTIALS path"
[[ ! -e "$credentials_path" ]] || fail "the credentials file $credentials_path survived the run"

# 2. Deploying an unchanged site is a no-op, not a failure: firebase answers HTTP 400 and exits
#    nonzero, and every release whose commit does not touch apps/web produces exactly this.
run_deploy "no-op" '{"status":"error","error":"Request to https://firebasehosting.googleapis.com/v1beta1/sites/spaces-a1814/releases had HTTP Error: 400, Version sites/spaces-a1814/versions/abc123 is the current active version"}' 1 "$SERVICE_ACCOUNT_JSON" \
    || fail "an unchanged-site deploy was treated as a failure"
grep -q "no-op" "$CURRENT_OUT" || fail "an unchanged-site deploy did not report itself as a no-op"

# 3. The quota failure that shipped a half-finished release has to fail the step, with the reason
#    visible in the log rather than buried in the CLI's raw output.
quota_error='Request to https://firebasehosting.googleapis.com/v1beta1/projects/-/sites/spaces-a1814/versions had HTTP Error: 429, You have exceeded the Hosting storage quota for your Firebase project, so you cannot deploy to your site right now.'
if run_deploy "quota" "{\"status\":\"error\",\"error\":\"$quota_error\"}" 1 "$SERVICE_ACCOUNT_JSON"; then
    fail "the Hosting storage quota error exited 0"
fi
grep -q "exceeded the Hosting storage quota" "$CURRENT_OUT" \
    || fail "the Hosting storage quota error was not printed"

# 4. Output that carries no readable result is a failure too, so a crashed or truncated CLI run
#    cannot pass as a deploy.
if run_deploy "unparseable" 'npm ERR! could not determine executable to run' 1 "$SERVICE_ACCOUNT_JSON"; then
    fail "an unparseable deploy result exited 0"
fi
grep -q "without a readable --json result" "$CURRENT_OUT" \
    || fail "an unparseable deploy result was not reported as such"

# 5. A missing secret fails before anything is deployed, rather than deploying unauthenticated.
if run_deploy "missing-secret" '{"status":"success","result":{}}' 0 ""; then
    fail "a missing FIREBASE_SERVICE_ACCOUNT exited 0"
fi
grep -q "FIREBASE_SERVICE_ACCOUNT is empty" "$CURRENT_OUT" \
    || fail "a missing FIREBASE_SERVICE_ACCOUNT was not reported"
[[ ! -s "$NPX_LOG" ]] || fail "a missing FIREBASE_SERVICE_ACCOUNT still invoked firebase-tools"

# 6. A working directory that holds no site fails before anything is deployed, rather than falling
#    back to some other apps/web. Promotion depends on this being an error: it runs main's copy of
#    the script, and the site it must deploy is the released commit's checkout it is run from.
NO_SITE_DIR="$TMP_ROOT/no-site"
mkdir -p "$NO_SITE_DIR"
if run_deploy "no-site" '{"status":"success","result":{}}' 0 "$SERVICE_ACCOUNT_JSON" "$NO_SITE_DIR"; then
    fail "running from a directory with no apps/web/firebase.json exited 0"
fi
grep -q "$NO_SITE_DIR/apps/web/firebase.json does not exist" "$CURRENT_OUT" \
    || fail "running from a directory with no site did not name the missing firebase.json"
[[ ! -s "$NPX_LOG" ]] || fail "running from a directory with no site still invoked firebase-tools"

echo "deploy-firebase-hosting result test passed"
