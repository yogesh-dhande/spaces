#!/usr/bin/env bash
set -euo pipefail

# Build, sign, package, and publish a muxy release.
#
# Usage:
#   scripts/release.sh
#
# Environment variables:
#   CODESIGN_IDENTITY  - Developer ID certificate (optional; ad-hoc if unset)
#   NOTARIZE           - Set to "1" to notarize via xcrun notarytool
#   APPLE_ID           - Apple ID for notarization
#   TEAM_ID            - Apple Developer Team ID for notarization
#   APP_PASSWORD       - App-specific password for notarization

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
macos_dir="$repo_root/apps/macos"
scripts_dir="$repo_root/scripts"

# Extract version from AppVersion.swift.
version_file="$macos_dir/Sources/streamctl/AppVersion.swift"
if [[ ! -f "$version_file" ]]; then
  echo "Error: $version_file not found" >&2
  exit 1
fi
VERSION=$(grep -oE '"[0-9]+\.[0-9]+\.[0-9]+"' "$version_file" | tr -d '"')
if [[ -z "$VERSION" ]]; then
  echo "Error: Could not extract version from $version_file" >&2
  exit 1
fi
echo "Building muxy v$VERSION"

# Build release configuration.
"$scripts_dir/swiftpm.sh" build -c release
echo "Build complete."

build_dir="$macos_dir/.build/release"
muxyapp_bin="$build_dir/MuxyApp"
muxy_bin="$build_dir/muxy"

if [[ ! -f "$muxyapp_bin" ]] || [[ ! -f "$muxy_bin" ]]; then
  echo "Error: Release binaries not found in $build_dir" >&2
  exit 1
fi

# Code sign.
"$scripts_dir/codesign.sh" "$muxyapp_bin" "$muxy_bin"

# Package into a zip.
staging_dir=$(mktemp -d)
trap 'rm -rf "$staging_dir"' EXIT
cp "$muxyapp_bin" "$staging_dir/"
cp "$muxy_bin" "$staging_dir/"

zip_name="MuxyApp-${VERSION}-macos.zip"
zip_path="$repo_root/$zip_name"
(cd "$staging_dir" && zip -q "$zip_path" MuxyApp muxy)
echo "Packaged: $zip_path"

# Notarize if requested.
if [[ "${NOTARIZE:-}" == "1" ]]; then
  if [[ -z "${APPLE_ID:-}" ]] || [[ -z "${TEAM_ID:-}" ]] || [[ -z "${APP_PASSWORD:-}" ]]; then
    echo "Error: APPLE_ID, TEAM_ID, and APP_PASSWORD are required for notarization" >&2
    exit 1
  fi
  echo "Submitting for notarization..."
  xcrun notarytool submit "$zip_path" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_PASSWORD" \
    --wait
  echo "Notarization complete."
fi

# Create GitHub release.
tag="v$VERSION"
echo "Creating GitHub release $tag..."
gh release create "$tag" "$zip_path" \
  --title "Muxy $VERSION" \
  --generate-notes

echo "Release $tag published."
