#!/usr/bin/env bash
set -euo pipefail

# Deploys apps/web to the live Firebase Hosting channel and fails the job when the deploy failed.
#
# This replaces FirebaseExtended/action-hosting-deploy on the three live-channel deploys (merge to
# main, release, promotion). The action fails its step on a deploy error, but the release and
# promotion workflows tolerated the HTTP 400 "is the current active version" no-op with
# `continue-on-error: true`, and that flag also hid every real error -- the Hosting storage quota
# answering HTTP 429, for one -- reaching the job as a green deploy step.
#
# One deploy error is not a failure: deploying a site that is byte-identical to what is already
# live answers HTTP 400 "is the current active version". Every release and promotion can hit it,
# because a release that changes nothing under apps/web produces the same static export, so it is
# treated as the no-op it is. Reading the CLI's --json result here is what keeps that no-op passing
# while a real failure fails the step, with no `continue-on-error` flag left to hide it.
#
# The PR preview workflow stays on the action: it deploys to a preview channel and comments the
# preview URL on the pull request, and it already fails the job on a deploy error because it
# carries no `continue-on-error`.

FIREBASE_TOOLS_VERSION="15.30.0"
PROJECT_ID="spaces-a1814"

# The site deployed is the apps/web of the directory this runs from, never one resolved relative to
# this file: the three workflows run it from the repository root of the checkout whose site they
# deploy, and promotion runs `main`'s copy of the script against a released commit's checkout, so
# locating the site relative to the script would deploy the wrong tree.
WEB_DIR="$PWD/apps/web"

if [[ ! -f "$WEB_DIR/firebase.json" ]]; then
  echo "Error: $WEB_DIR/firebase.json does not exist, so there is no Firebase Hosting site here to deploy. Run this from the repository root of the checkout whose site should be deployed." >&2
  exit 1
fi

if [[ -z "${FIREBASE_SERVICE_ACCOUNT:-}" ]]; then
  echo "Error: FIREBASE_SERVICE_ACCOUNT is empty. Pass the FIREBASE_SERVICE_ACCOUNT_SPACES_A1814 secret in the step's env." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is not installed, so the deploy result cannot be read. A swallowed deploy failure is the thing this script exists to prevent, so it refuses to run blind." >&2
  exit 1
fi

# The service account JSON reaches the CLI only as a file, private to this process and removed
# however the script ends.
CREDENTIALS_FILE="$(mktemp "${TMPDIR:-/tmp}/spaces-firebase-credentials.XXXXXX")"
trap 'rm -f "$CREDENTIALS_FILE"' EXIT
chmod 600 "$CREDENTIALS_FILE"
printf '%s' "$FIREBASE_SERVICE_ACCOUNT" > "$CREDENTIALS_FILE"
export GOOGLE_APPLICATION_CREDENTIALS="$CREDENTIALS_FILE"

echo "Deploying $WEB_DIR to the live Firebase Hosting channel of ${PROJECT_ID}..."

# `npx --yes` because a runner has no firebase-tools cached and npx otherwise stops to ask before
# installing. The version is pinned so a firebase-tools release cannot change deploy behavior
# under an unchanged workflow.
deploy_status=0
deploy_output="$(cd "$WEB_DIR" && npx --yes "firebase-tools@$FIREBASE_TOOLS_VERSION" \
  deploy --only hosting --project "$PROJECT_ID" --non-interactive --json)" || deploy_status=$?

result_status="$(printf '%s' "$deploy_output" | jq -r '.status // empty' 2>/dev/null || true)"

case "$result_status" in
  success)
    printf '%s' "$deploy_output" | jq -r '.result.hosting // empty'
    echo "✓ Deployed to the live channel of $PROJECT_ID"
    exit 0
    ;;
  error)
    error_text="$(printf '%s' "$deploy_output" | jq -r '.error // empty')"
    if [[ "$error_text" == *"is the current active version"* ]]; then
      echo "✓ The built site is byte-identical to the live version, so this deploy is a no-op: $error_text"
      exit 0
    fi
    echo "Error: the Firebase Hosting deploy failed: $error_text" >&2
    exit 1
    ;;
  *)
    echo "Error: the Firebase Hosting deploy exited $deploy_status without a readable --json result:" >&2
    printf '%s\n' "$deploy_output" >&2
    exit 1
    ;;
esac
