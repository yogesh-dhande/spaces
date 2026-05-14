#!/usr/bin/env python3

import os
from pathlib import Path


EXTERNAL_ATTACH_SYMBOLS = [
    "ghostty_surface_attach",
    "ghostty_surface_adopt",
    "ghostty_surface_set_pty",
    "ghostty_surface_set_fd",
    "ghostty_surface_set_io",
    "ghostty_surface_attach_stream",
    "ghostty_surface_connect",
]


def resolve_header_path(repo_root: Path) -> Path:
    env_override = os.environ.get("SPACES_GHOSTTYKIT_XCFRAMEWORK")
    if env_override:
        base = Path(env_override)
    else:
        base = repo_root / "apps/macos/.local/ghosttykit/GhosttyKit.xcframework"
    return base / "macos-arm64_x86_64/Headers/ghostty.h"


def main() -> int:
    repo_root = Path(__file__).resolve().parents[3]
    header_path = resolve_header_path(repo_root)
    if not header_path.exists():
        raise SystemExit(f"Ghostty header not found at {header_path}")

    header = header_path.read_text(encoding="utf-8")
    has_launch_surface = all(
        needle in header for needle in ["working_directory", "command", "env_vars", "initial_input", "wait_after_command"]
    )
    has_raw_input = "ghostty_surface_send_input_raw" in header
    has_data_callback = "ghostty_surface_set_data_callback" in header
    has_cell_readback = all(needle in header for needle in ["ghostty_surface_read_cells", "ghostty_surface_free_cells"])
    has_tty_inspection = all(needle in header for needle in ["ghostty_surface_tty_name", "ghostty_surface_foreground_pid"])
    has_external_attach = any(symbol in header for symbol in EXTERNAL_ATTACH_SYMBOLS)

    print(f"Ghostty shared-session client capability probe")
    print(f"  header: {header_path}")
    print(f"  launch-owned surface config: {'yes' if has_launch_surface else 'no'}")
    print(f"  raw input API: {'yes' if has_raw_input else 'no'}")
    print(f"  data callback API: {'yes' if has_data_callback else 'no'}")
    print(f"  cell readback API: {'yes' if has_cell_readback else 'no'}")
    print(f"  tty inspection API: {'yes' if has_tty_inspection else 'no'}")
    print(f"  external session attach API: {'yes' if has_external_attach else 'no'}")

    if has_launch_surface and has_raw_input and has_data_callback and has_cell_readback and has_tty_inspection and not has_external_attach:
        print("")
        print("Conclusion: the public Ghostty SDK is strong enough for a local embedded renderer,")
        print("but it still lacks an attach/adopt API for an externally owned PTY or session stream.")
        print("Spaces cannot use public libghostty as the option-1 shared-session client renderer yet.")
        return 0

    if has_external_attach:
        print("")
        print("Conclusion: attach/adopt symbols are present. Re-evaluate the transport-backed libghostty client path.")
        return 0

    raise SystemExit("Ghostty capability probe failed: missing expected local renderer hooks.")


if __name__ == "__main__":
    raise SystemExit(main())
