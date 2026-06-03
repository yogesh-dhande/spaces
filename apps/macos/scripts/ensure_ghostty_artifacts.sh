#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/setup_ghostty.sh"

SUBMODULE_PATH="apps/macos/vendor/ghostty"
GHOSTTY_SOURCE_ROOT="$REPO_ROOT/$SUBMODULE_PATH"
ARTIFACT_REPO="${SPACES_GHOSTTY_ARTIFACT_REPO:-${GITHUB_REPOSITORY:-yogesh-dhande/spaces}}"
ARTIFACT_RELEASE_PREFIX="ghostty-artifacts-"

PUBLISH_MISSING=0
PACKAGE_PARENT=""

usage() {
    cat <<'EOF'
Usage: apps/macos/scripts/ensure_ghostty_artifacts.sh [--publish-missing]

Ensures Ghostty artifacts for the pinned submodule SHA are installed locally.
Existing artifact releases are downloaded and strictly validated. Missing releases
are built from the pinned submodule. With --publish-missing, a missing or invalid
release is published after a successful strict build.
EOF
}

die() {
    echo "$*" >&2
    exit 1
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --publish-missing)
            PUBLISH_MISSING=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "unknown ensure_ghostty_artifacts.sh argument: $1"
            ;;
    esac
done

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

submodule_is_initialized() {
    git -C "$GHOSTTY_SOURCE_ROOT" rev-parse --git-dir >/dev/null 2>&1
}

resolve_ghostty_sha() {
    local gitlink_sha
    gitlink_sha="$(git -C "$REPO_ROOT" ls-files -s -- "$SUBMODULE_PATH" | awk '$1 == "160000" { print $2; exit }')"
    if [[ -n "$gitlink_sha" ]]; then
        echo "$gitlink_sha"
        return
    fi

    if submodule_is_initialized; then
        git -C "$GHOSTTY_SOURCE_ROOT" rev-parse HEAD
    fi
}

ensure_submodule_matches_pin() {
    if ! submodule_is_initialized; then
        return
    fi

    local head_sha
    head_sha="$(git -C "$GHOSTTY_SOURCE_ROOT" rev-parse HEAD)"
    if [[ "$head_sha" != "$GHOSTTY_SHA" ]]; then
        die "Ghostty submodule HEAD $head_sha does not match pinned gitlink $GHOSTTY_SHA"
    fi
}

artifact_release_tag() {
    printf "%s%s\n" "$ARTIFACT_RELEASE_PREFIX" "$GHOSTTY_SHA"
}

release_exists() {
    local output
    if output="$(gh release view "$RELEASE_TAG" --repo "$ARTIFACT_REPO" 2>&1)"; then
        return 0
    fi

    if grep -qiE 'not found|HTTP 404|release not found' <<<"$output"; then
        return 1
    fi

    die "failed to inspect Ghostty artifact release $RELEASE_TAG in $ARTIFACT_REPO: $output"
}

wait_for_release_exists() {
    local attempt
    for attempt in 1 2 3 4 5; do
        if release_exists; then
            return 0
        fi

        sleep "$attempt"
    done

    return 1
}

package_dir() {
    if [[ -n "${RUNNER_TEMP:-}" ]]; then
        printf "%s/ghostty-artifacts\n" "$RUNNER_TEMP"
        return
    fi

    printf "%s/ghostty-artifacts\n" "$PACKAGE_PARENT"
}

verify_packaged_artifacts() {
    local artifact_dir="$1"
    local assets=(
        "$artifact_dir/GhosttyKit.xcframework.tar.gz"
        "$artifact_dir/GhosttyKit-resources.tar.gz"
        "$artifact_dir/libghostty-vt.tar.gz"
        "$artifact_dir/manifest.json"
        "$artifact_dir/SHA256SUMS"
    )

    for asset in "${assets[@]}"; do
        [[ -f "$asset" ]] || die "missing packaged Ghostty artifact: $asset"
    done

    (cd "$artifact_dir" && shasum -a 256 -c SHA256SUMS)
}

upload_packaged_artifacts() {
    local upload_output
    local assets=("$@")

    if upload_output="$(gh release upload "$RELEASE_TAG" "${assets[@]}" --repo "$ARTIFACT_REPO" --clobber 2>&1)"; then
        return
    fi

    echo "==> Upload to $RELEASE_TAG failed; checking whether another publisher completed the release"
    if "$SETUP_SCRIPT" --download-only --strict; then
        echo "==> Ghostty artifact release $RELEASE_TAG already contains valid artifacts"
        return
    fi

    printf "%s\n" "$upload_output" >&2
    die "failed to upload Ghostty artifacts to $RELEASE_TAG in $ARTIFACT_REPO"
}

existing_release_is_valid() {
    "$SETUP_SCRIPT" --download-only --strict
}

publish_packaged_artifacts() {
    local artifact_dir="$1"
    local release_title="Ghostty artifacts $GHOSTTY_SHA"
    local create_output
    local assets=(
        "$artifact_dir/GhosttyKit.xcframework.tar.gz"
        "$artifact_dir/GhosttyKit-resources.tar.gz"
        "$artifact_dir/libghostty-vt.tar.gz"
        "$artifact_dir/manifest.json"
        "$artifact_dir/SHA256SUMS"
    )

    verify_packaged_artifacts "$artifact_dir"

    if release_exists; then
        echo "==> Revalidating existing Ghostty artifact release $RELEASE_TAG before upload"
        if existing_release_is_valid; then
            echo "==> Existing Ghostty artifact release $RELEASE_TAG is valid; skipping publish"
            return
        fi

        echo "==> Existing Ghostty artifact release $RELEASE_TAG is invalid or incomplete; uploading repair assets"
        gh release edit "$RELEASE_TAG" --repo "$ARTIFACT_REPO" --title "$release_title"
        upload_packaged_artifacts "${assets[@]}"
        return
    fi

    if create_output="$(
        gh release create "$RELEASE_TAG" "${assets[@]}" \
            --repo "$ARTIFACT_REPO" \
            --title "$release_title" \
            --notes "Prebuilt Ghostty artifacts for $GHOSTTY_SHA." 2>&1
    )"; then
        return
    fi

    if wait_for_release_exists; then
        echo "==> Ghostty artifact release $RELEASE_TAG appeared during create; revalidating before upload"
        if existing_release_is_valid; then
            echo "==> Existing Ghostty artifact release $RELEASE_TAG is valid; skipping publish"
            return
        fi

        echo "==> Existing Ghostty artifact release $RELEASE_TAG is invalid or incomplete; uploading repair assets"
        gh release edit "$RELEASE_TAG" --repo "$ARTIFACT_REPO" --title "$release_title"
        upload_packaged_artifacts "${assets[@]}"
    else
        printf "%s\n" "$create_output" >&2
        die "failed to create Ghostty artifact release $RELEASE_TAG in $ARTIFACT_REPO"
    fi
}

cleanup() {
    if [[ -n "$PACKAGE_PARENT" ]]; then
        rm -rf "$PACKAGE_PARENT"
    fi
}
trap cleanup EXIT

command_exists gh || die "GitHub CLI 'gh' is required to ensure Ghostty artifacts"

GHOSTTY_SHA="$(resolve_ghostty_sha)"
[[ -n "$GHOSTTY_SHA" ]] || die "unable to resolve Ghostty submodule SHA at $SUBMODULE_PATH"
ensure_submodule_matches_pin
RELEASE_TAG="$(artifact_release_tag)"

if release_exists; then
    echo "==> Found Ghostty artifact release $RELEASE_TAG in $ARTIFACT_REPO"
    if "$SETUP_SCRIPT" --download-only --strict; then
        exit 0
    fi

    if [[ "$PUBLISH_MISSING" -ne 1 ]]; then
        die "existing Ghostty artifact release $RELEASE_TAG is invalid or incomplete"
    fi

    echo "==> Existing Ghostty artifact release is invalid or incomplete; rebuilding for repair"
else
    echo "==> Ghostty artifact release $RELEASE_TAG is missing in $ARTIFACT_REPO"
fi

if [[ -z "${RUNNER_TEMP:-}" ]]; then
    PACKAGE_PARENT="$(mktemp -d)"
fi
artifact_dir="$(package_dir)"
"$SETUP_SCRIPT" --build --strict --package "$artifact_dir"

if [[ "$PUBLISH_MISSING" -eq 1 ]]; then
    publish_packaged_artifacts "$artifact_dir"
else
    verify_packaged_artifacts "$artifact_dir"
    echo "==> Skipping Ghostty artifact release publish"
fi
