#!/usr/bin/env bash
# Installs the Spaces Linux daemon (spacesd), for the latest released version
# or a specific requested version.
#
# This is the single, user-runnable install/upgrade path for Linux devices. It
# downloads the signed remote-artifact manifest for the requested (or latest)
# version, verifies its Ed25519 signature against the embedded public key,
# downloads and checksums the matching Ubuntu 24.04 archive, then runs the
# bundled install.sh (which lays out ~/.spaces, ~/.local/bin/spaces, and the
# systemd user service).
#
# Served at https://usespaces.dev/install.sh via the web app's prebuild copy
# (apps/web/package.json). Two invocations:
#   curl -fsSL https://usespaces.dev/install.sh | bash
#     Installs the latest published release.
#   curl -fsSL https://usespaces.dev/install.sh | bash -s -- 0.1.0
#     Installs a specific version. This is the form printed by the Spaces app
#     when pairing requires a wire-compatible daemon version.
#
# The embedded REMOTE_ARTIFACT_PUBLIC_KEY must stay in sync with
# AppVersion.remoteArtifactPublicKey; workspacecoreTests' installer drift test
# enforces that. Update both when rotating the remote-artifact signing key.
set -euo pipefail

REPOSITORY="yogesh-dhande/spaces"
RELEASE_BASE_URL="https://github.com/${REPOSITORY}/releases/download"
REMOTE_ARTIFACT_PUBLIC_KEY="R3qsBslT0G/A5YvsoqZu0s/lFrkSNf5zq+yuzAqmTMo="

die() {
    echo "spaces-install-linux: $*" >&2
    exit 1
}

version="${1:-}"
version="${version#v}"
if [[ -n "$version" ]]; then
    base_url="${RELEASE_BASE_URL}/v${version}"
else
    # No version requested: GitHub's stable redirect to the newest release's assets.
    base_url="https://github.com/${REPOSITORY}/releases/latest/download"
fi

for tool in curl tar sha256sum openssl python3; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

os="$(uname -s 2>/dev/null || true)"
[[ "$os" == "Linux" ]] || die "the Spaces daemon installs on Linux only (detected $os)."
# shellcheck disable=SC1091
. /etc/os-release 2>/dev/null || die "could not read /etc/os-release to identify this Linux distribution."
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] \
    || die "the Spaces daemon supports Ubuntu 24.04 (detected ${ID:-unknown} ${VERSION_ID:-unknown})."
case "$(uname -m 2>/dev/null || true)" in
    x86_64 | amd64) arch="x86_64" ;;
    aarch64 | arm64) arch="arm64" ;;
    *) die "the Spaces daemon supports x86_64 and arm64 (detected $(uname -m))." ;;
esac
platform="ubuntu-24.04"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

manifest_path="$workdir/spaces-remote-artifacts.json"
signature_path="$workdir/spaces-remote-artifacts.json.sig"
curl -fsSL "$base_url/spaces-remote-artifacts.json" -o "$manifest_path" \
    || die "could not download the installer manifest from $base_url. Confirm that the requested Spaces release is published."
curl -fsSL "$base_url/spaces-remote-artifacts.json.sig" -o "$signature_path" \
    || die "could not download the installer signature from $base_url."

# Verify the manifest signature. The 44-byte Ed25519 SubjectPublicKeyInfo is the
# fixed 12-byte DER prefix (base64 "MCowBQYDK2VwAyEA") followed by the raw key,
# so the two base64 chunks concatenate directly (12 is a multiple of 3).
public_key_pem="$workdir/remote-artifact-public-key.pem"
printf '%s\n%s\n%s\n' \
    "-----BEGIN PUBLIC KEY-----" \
    "MCowBQYDK2VwAyEA${REMOTE_ARTIFACT_PUBLIC_KEY}" \
    "-----END PUBLIC KEY-----" >"$public_key_pem"
openssl pkeyutl -verify -pubin -inkey "$public_key_pem" -rawin -in "$manifest_path" -sigfile "$signature_path" >/dev/null 2>&1 \
    || die "the installer manifest signature did not verify. Do not proceed; the download may be tampered with."

# Only derive the version from the manifest after its signature verifies above;
# never trust unverified content for the version that gates artifact selection.
if [[ -z "$version" ]]; then
    version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("app_version",""))' "$manifest_path")"
    [[ -n "$version" ]] || die "the latest release manifest does not declare an app_version."
fi

selection="$(python3 - "$manifest_path" "$version" "$platform" "$arch" <<'PY'
import json
import sys

manifest_path, version, platform, arch = sys.argv[1:5]
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)

if manifest.get("schema_version") != 1:
    sys.exit("unsupported installer manifest schema version.")
if manifest.get("app_version") != version:
    sys.exit(f"manifest is for version {manifest.get('app_version')}, not the requested {version}.")

for artifact in manifest.get("artifacts", []):
    if artifact.get("version") == version and artifact.get("platform") == platform and artifact.get("architecture") == arch:
        url = artifact.get("url", "")
        sha256 = artifact.get("sha256", "")
        if not url.startswith("https://"):
            sys.exit("artifact download URL must be https.")
        if not sha256:
            sys.exit("artifact is missing its sha256 checksum.")
        print(url)
        print(sha256)
        break
else:
    sys.exit(f"no {platform} {arch} artifact for version {version} in the manifest.")
PY
)" || die "could not select a Linux daemon artifact from the manifest."
artifact_url="$(printf '%s\n' "$selection" | sed -n '1p')"
artifact_sha256="$(printf '%s\n' "$selection" | sed -n '2p')"

archive_path="$workdir/spacesd-${platform}-${arch}.tar.gz"
curl -fsSL "$artifact_url" -o "$archive_path" || die "could not download the Linux daemon artifact from $artifact_url."
echo "${artifact_sha256}  ${archive_path}" | sha256sum -c - >/dev/null 2>&1 \
    || die "the Linux daemon artifact failed its checksum. Do not proceed; the download may be corrupt or tampered with."

extract_dir="$workdir/extract"
mkdir -p "$extract_dir"
tar -xzf "$archive_path" -C "$extract_dir"
install_script="$(find "$extract_dir" -maxdepth 2 -type f -name install.sh | head -n 1)"
[[ -n "$install_script" ]] || die "the Linux daemon artifact did not contain install.sh."
chmod +x "$install_script"

echo "spaces-install-linux: installing Spaces daemon $version ($platform $arch)..."
SPACESD_VERSION="$version" bash "$install_script"
echo "spaces-install-linux: Spaces daemon $version installed."
