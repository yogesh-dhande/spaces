#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  echo "Usage: $0 <version> <release-tag> <artifact-dir>" >&2
  exit 64
fi

VERSION="$1"
RELEASE_TAG="$2"
ARTIFACT_DIR="$3"

: "${REMOTE_ARTIFACT_PRIVATE_ED25519_KEY:?Set REMOTE_ARTIFACT_PRIVATE_ED25519_KEY to the base64 raw Ed25519 seed or PEM private key.}"

repository="${GITHUB_REPOSITORY:-yogesh-dhande/spaces}"
base_url="https://github.com/${repository}/releases/download/${RELEASE_TAG}"
manifest_path="$ARTIFACT_DIR/spaces-remote-artifacts.json"
signature_path="$ARTIFACT_DIR/spaces-remote-artifacts.json.sig"

python3 - "$VERSION" "$RELEASE_TAG" "$ARTIFACT_DIR" "$base_url" "$manifest_path" "$signature_path" <<'PY'
import base64
import hashlib
import json
import os
import pathlib
import sys

try:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
except ImportError as exc:
    raise SystemExit("Python package 'cryptography' is required to sign remote artifact manifests.") from exc

version, release_tag, artifact_dir, base_url, manifest_path, signature_path = sys.argv[1:7]
artifact_dir = pathlib.Path(artifact_dir)
manifest_path = pathlib.Path(manifest_path)
signature_path = pathlib.Path(signature_path)

specs = [
    ("spacesd-ubuntu-24.04-x86_64", "ubuntu-24.04", "x86_64", "spacesd-ubuntu-24.04-x86_64.tar.gz"),
    ("spacesd-ubuntu-24.04-arm64", "ubuntu-24.04", "arm64", "spacesd-ubuntu-24.04-arm64.tar.gz"),
]

artifacts = []
for artifact_id, platform, architecture, archive_name in specs:
    archive_path = artifact_dir / archive_name
    if not archive_path.is_file():
        raise SystemExit(f"missing remote artifact archive: {archive_path}")
    digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
    artifacts.append({
        "id": artifact_id,
        "version": version,
        "platform": platform,
        "architecture": architecture,
        "archive_name": archive_name,
        "url": f"{base_url}/{archive_name}",
        "sha256": digest,
    })

manifest = {
    "schema_version": 1,
    "app_version": version,
    "release_tag": release_tag,
    "artifacts": artifacts,
}
data = json.dumps(manifest, indent=2, sort_keys=True, separators=(",", ": ")).encode("utf-8") + b"\n"
manifest_path.write_bytes(data)

key_value = os.environ["REMOTE_ARTIFACT_PRIVATE_ED25519_KEY"].strip()
private_key = None
if key_value.startswith("-----BEGIN"):
    private_key = serialization.load_pem_private_key(key_value.encode("utf-8"), password=None)
else:
    padded = key_value + ("=" * ((4 - len(key_value) % 4) % 4))
    seed = base64.urlsafe_b64decode(padded.encode("ascii"))
    if len(seed) != 32:
        raise SystemExit("REMOTE_ARTIFACT_PRIVATE_ED25519_KEY raw seed must decode to 32 bytes.")
    private_key = Ed25519PrivateKey.from_private_bytes(seed)

signature_path.write_bytes(private_key.sign(data))
PY

echo "Wrote $manifest_path"
echo "Wrote $signature_path"
