#!/usr/bin/env python3
import argparse
import base64
import json
import math
import subprocess
import sys
import time
import uuid
from pathlib import Path


PROCESS_NAME = "parity-process"
AGENT_NAME = "parity-agent"
REMOTE_WEB_SESSION_NAME = "remote-web"

# Terminal background colors the Spaces theme (spaces-brand) exports per appearance, packed as
# 0x00RRGGBB — the same form a decoded render frame carries as defaultBackgroundRGB. Kept in sync with
# ThemeRegistry.spacesBrand{Light,Dark}Terminal.background in
# apps/macos/Sources/spacesterminalcore/Theming/ThemeRegistry.swift.
TERMINAL_BACKGROUND_RGB = {
    "light": (248 << 16) | (247 << 8) | 241,
    "dark": (15 << 16) | (21 << 8) | 23,
}

# GhosttyRenderUpdate.currentVersion. Bumped in lockstep with the Swift codec.
RENDER_UPDATE_VERSION = 4


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the shared Spaces Device API local/remote parity flow.")
    parser.add_argument("--spacese2e", required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--certificate-fingerprint", required=True)
    parser.add_argument("--auth-token", required=True)
    parser.add_argument("--project-dir", required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--result-json")
    parser.add_argument("--terminal-latency-json")
    parser.add_argument("--terminal-latency-samples", type=int, default=3)
    parser.add_argument("--client-installation-id", default="")
    parser.add_argument("--client-device-name", default="")
    return parser.parse_args()


def client_app(args: argparse.Namespace) -> dict:
    return {
        "installationID": args.client_installation_id.strip() or str(uuid.uuid4()).upper(),
        "bundleID": "dev.usespaces.spacesmobile",
        "platform": "ios",
        "deviceName": args.client_device_name.strip() or f"Device API Parity {args.label}",
        "appVersion": "1.0",
    }


def typed_request(command: str, payload: dict | None, args: argparse.Namespace, app: dict) -> dict:
    return {
        "authToken": args.auth_token,
        "clientApp": app,
        "command": {command: payload or {}},
    }


def send(command: str, payload: dict | None, args: argparse.Namespace, app: dict) -> dict:
    print(f"[device-api-parity:{args.label}] {command}", file=sys.stderr, flush=True)
    started = time.perf_counter()
    command_args = [
        args.spacese2e,
        "mobile-request",
        "--host",
        args.host,
        "--port",
        str(args.port),
        f"--certificate-fingerprint={args.certificate_fingerprint}",
        "--request-json",
        json.dumps(typed_request(command, payload, args, app), separators=(",", ":")),
    ]
    try:
        completed = subprocess.run(command_args, check=True, capture_output=True, text=True, timeout=30)
    except subprocess.CalledProcessError as error:
        raise RuntimeError(
            f"{command} request failed with exit status {error.returncode}\nstdout={error.stdout!r}\nstderr={error.stderr!r}"
        ) from error
    try:
        response = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(
            f"invalid JSON response for {command}: {error}\nstdout={completed.stdout!r}\nstderr={completed.stderr!r}"
        ) from error
    timings = getattr(args, "_request_timings", None)
    if isinstance(timings, list):
        record = {
            "command": command,
            "elapsed_ms": round((time.perf_counter() - started) * 1000, 3),
            "ok": response.get("ok") is True,
        }
        session_id = (payload or {}).get("sessionID")
        if session_id:
            record["session_id"] = session_id
        timings.append(record)
    return response


def require_ok(response: dict, context: str) -> None:
    if response.get("ok") is not True:
        raise AssertionError(f"{context} failed: {json.dumps(response, indent=2, sort_keys=True)}")


def result(response: dict, kind: str, context: str) -> dict:
    require_ok(response, context)
    value = response.get("result")
    if not isinstance(value, dict) or sorted(value.keys()) != [kind]:
        raise AssertionError(f"{context} did not return typed result {kind}: {json.dumps(response, indent=2, sort_keys=True)}")
    payload = value[kind]
    if not isinstance(payload, dict):
        raise AssertionError(f"{context} result {kind} was not an object: {json.dumps(response, indent=2, sort_keys=True)}")
    return payload


def mutation(response: dict, context: str) -> dict:
    return result(response, "mutation", context)


def overview_from_response(response: dict, context: str) -> dict:
    return result(response, "overview", context)


def overview_from_mutation(response: dict, context: str) -> dict:
    payload = mutation(response, context)
    overview = payload.get("overview")
    if not isinstance(overview, dict):
        raise AssertionError(f"{context} mutation did not include overview: {json.dumps(response, indent=2, sort_keys=True)}")
    return overview


def wait_for(predicate, describe: str, timeout: float = 45.0, interval: float = 0.5):
    deadline = time.monotonic() + timeout
    last_value = None
    while time.monotonic() < deadline:
        last_value = predicate()
        if last_value:
            return last_value
        time.sleep(interval)
    raise TimeoutError(f"timed out waiting for {describe}; last={json.dumps(last_value, indent=2, sort_keys=True) if isinstance(last_value, dict) else last_value!r}")


def percentile(values: list[float], pct: float) -> float:
    ordered = sorted(values)
    return ordered[max(math.ceil(len(ordered) * pct) - 1, 0)]


def summarize_values(values: list[float]) -> dict:
    if not values:
        return {
            "count": 0,
            "p50_ms": None,
            "p95_ms": None,
            "max_ms": None,
        }
    midpoint = len(values) // 2
    ordered = sorted(values)
    if len(ordered) % 2 == 0:
        median = (ordered[midpoint - 1] + ordered[midpoint]) / 2
    else:
        median = ordered[midpoint]
    return {
        "count": len(values),
        "p50_ms": round(median, 3),
        "p95_ms": round(percentile(values, 0.95), 3),
        "max_ms": round(max(values), 3),
    }


def summarize_numbers(values: list[float]) -> dict:
    if not values:
        return {
            "count": 0,
            "p50": None,
            "p95": None,
            "max": None,
        }
    midpoint = len(values) // 2
    ordered = sorted(values)
    if len(ordered) % 2 == 0:
        median = (ordered[midpoint - 1] + ordered[midpoint]) / 2
    else:
        median = ordered[midpoint]
    return {
        "count": len(values),
        "p50": round(median, 3),
        "p95": round(percentile(values, 0.95), 3),
        "max": round(max(values), 3),
    }


def summarize_measurements(measurements: list[dict], key: str) -> dict:
    return summarize_values([float(item[key]) for item in measurements if item.get(key) is not None])


def find_workspace(overview: dict, workspace_id: str) -> dict | None:
    for workspace in overview.get("workspaces") or []:
        if workspace.get("id") == workspace_id:
            return workspace
    return None


def find_named_row(workspace: dict, key: str, name: str) -> dict | None:
    for row in workspace.get(key) or []:
        if row.get("name") == name or row.get("title") == name:
            return row
    return None


def current_overview(args: argparse.Namespace, app: dict) -> dict:
    return overview_from_response(send("overview", {}, args, app), "overview")


def is_e2e_project(project: dict) -> bool:
    name = str(project.get("name") or "")
    directory = str(project.get("dir") or "")
    return name.startswith("device-api-") or "/device-api-project-" in directory


def cleanup_prior_e2e_projects(args: argparse.Namespace, app: dict, overview: dict) -> None:
    for project in overview.get("projects") or []:
        project_id = project.get("id")
        if not project_id or not is_e2e_project(project):
            continue
        mutation(send("deleteProject", {"projectID": project_id}, args, app), f"deleteProject {project_id}")


def workspace_overview(args: argparse.Namespace, app: dict, workspace_id: str) -> dict:
    # The daemon rebuilds the overview asynchronously after a mutation, so a read issued
    # right after createWorkspace can race the rebuild; poll like the other overview waits.
    def attempt():
        overview = current_overview(args, app)
        return find_workspace(overview, workspace_id)

    return wait_for(attempt, f"overview to include workspace {workspace_id}")


def wait_for_terminal_state(args: argparse.Namespace, app: dict, session_id: str) -> dict:
    def attempt():
        response = send("state", {"sessionID": session_id}, args, app)
        if response.get("ok") is not True:
            return None
        return result(response, "terminalState", f"state {session_id}")

    return wait_for(attempt, f"terminal state {session_id}")


def terminal_control_payload(action: str, session_id: str, **values: object) -> dict:
    payload: dict[str, object] = {"action": action, "sessionID": session_id, "appendNewline": False, "asPaste": False}
    payload.update({key: value for key, value in values.items() if value is not None})
    return payload


def terminal_client(client_id: str, label: str) -> dict:
    return {
        "id": client_id,
        "kind": "remoteViewer",
        "identity": {
            "label": label,
            "deviceName": label,
            "networkAddress": "127.0.0.1",
        },
        "connectedAt": "2026-06-02T12:00:00Z",
        "disconnectedAt": None,
    }


def terminal_progress(state: dict) -> tuple[int, int]:
    output_count = int(state.get("outputByteCount") or 0)
    screen_revision = int(state.get("screenStateRevision") or 0)
    return output_count, screen_revision


def wait_for_terminal_progress(
    args: argparse.Namespace,
    app: dict,
    session_id: str,
    previous_output_count: int,
    previous_screen_revision: int,
    timeout: float = 10.0,
) -> tuple[dict, dict]:
    started = time.perf_counter()
    deadline = started + timeout
    poll_count = 0
    state_request_measurements: list[float] = []
    last_state: dict | None = None
    while time.perf_counter() < deadline:
        state_started = time.perf_counter()
        response = send("state", {"sessionID": session_id}, args, app)
        state_request_measurements.append(round((time.perf_counter() - state_started) * 1000, 3))
        if response.get("ok") is True:
            state = result(response, "terminalState", f"state {session_id}")
            last_state = state
            output_count, screen_revision = terminal_progress(state)
            poll_count += 1
            if output_count > previous_output_count or screen_revision > previous_screen_revision:
                return state, {
                    "poll_count": poll_count,
                    "state_request_ms": state_request_measurements[-1],
                    "state_request_summary": summarize_values(state_request_measurements),
                    "terminal_output_byte_delta": output_count - previous_output_count,
                    "screen_revision_delta": screen_revision - previous_screen_revision,
                    "wait_ms": round((time.perf_counter() - started) * 1000, 3),
                }
        time.sleep(0.05)
    raise TimeoutError(
        "timed out waiting for terminal output progress; "
        f"previous_output_count={previous_output_count} previous_screen_revision={previous_screen_revision} "
        f"last_state={json.dumps(last_state, indent=2, sort_keys=True) if last_state else None}"
    )


def run_terminal_latency_probe(
    args: argparse.Namespace,
    app: dict,
    session_id: str,
    open_request_ms: float,
    ready_wait_ms: float,
    ready_state: dict,
) -> dict:
    sample_count = max(args.terminal_latency_samples, 1)
    client_id = str(uuid.uuid4()).upper()
    require_ok(
        send(
            "terminalControl",
            terminal_control_payload(
                "attach",
                session_id,
                clientID=client_id,
                client=terminal_client(client_id, f"Device API Parity {args.label}"),
                attachmentMode="owner",
            ),
            args,
            app,
        ),
        "terminal latency attach",
    )

    before_output_count, before_screen_revision = terminal_progress(ready_state)
    measurements: list[dict] = []
    for index in range(sample_count):
        token = f"__spaces_parity_latency_{index + 1:03d}_{uuid.uuid4().hex[:8]}__"
        command_text = f"printf '{token}\\n'"
        sample_started = time.perf_counter()
        send_started = time.perf_counter()
        response = send(
            "terminalControl",
            terminal_control_payload(
                "send",
                session_id,
                clientID=client_id,
                text=command_text,
                appendNewline=True,
            ),
            args,
            app,
        )
        send_request_ms = round((time.perf_counter() - send_started) * 1000, 3)
        require_ok(response, f"terminal latency send {index + 1}")
        state, progress = wait_for_terminal_progress(args, app, session_id, before_output_count, before_screen_revision)
        output_count, screen_revision = terminal_progress(state)
        before_output_count = output_count
        before_screen_revision = screen_revision
        measurements.append(
            {
                "sample_index": index + 1,
                "send_request_ms": send_request_ms,
                "send_to_state_progress_ms": round((time.perf_counter() - sample_started) * 1000, 3),
                "state_request_ms": progress["state_request_ms"],
                "state_poll_count": progress["poll_count"],
                "terminal_output_byte_delta": progress["terminal_output_byte_delta"],
                "screen_revision_delta": progress["screen_revision_delta"],
            }
        )

    request_timings = getattr(args, "_request_timings", [])
    terminal_request_timings = [
        item
        for item in request_timings
        if item.get("command") in ("openWorkspaceTerminal", "state", "terminalControl")
        and item.get("session_id") in (None, session_id)
    ]
    return {
        "suite": "device-api-terminal-latency",
        "label": args.label,
        "terminal_target": "device-api",
        "session_id": session_id,
        "samples": sample_count,
        "open_workspace_terminal_request_ms": round(open_request_ms, 3),
        "terminal_state_ready_wait_ms": round(ready_wait_ms, 3),
        "measurements": measurements,
        "summary_metric": "send_to_state_progress_ms",
        "summary": summarize_measurements(measurements, "send_to_state_progress_ms"),
        "phase_summaries": {
            "send_request": summarize_measurements(measurements, "send_request_ms"),
            "state_request": summarize_measurements(measurements, "state_request_ms"),
        },
        "progress_summary": {
            "state_poll_count": summarize_numbers([float(item["state_poll_count"]) for item in measurements]),
            "screen_revision_delta": summarize_numbers([float(item["screen_revision_delta"]) for item in measurements]),
            "terminal_output_byte_delta": summarize_numbers([float(item["terminal_output_byte_delta"]) for item in measurements]),
        },
        "request_summaries": {
            command: summarize_values([float(item["elapsed_ms"]) for item in terminal_request_timings if item.get("command") == command])
            for command in ("openWorkspaceTerminal", "state", "terminalControl")
        },
    }


def decode_full_frame_default_background_rgb(render_update_b64: str) -> int:
    """Decodes a self-contained (full) render update and returns its default background RGB (0x00RRGGBB).

    The `state` Device API command always exports a full self-contained frame, so only the full-frame
    header + snapshot prologue up to the background colour is parsed here; deltas are never returned by
    `state` and nothing past the colour is read. Mirrors the GRTU v4 wire format written by
    GhosttyRenderUpdateBinaryCodec and decoded by profile_device_api.sh / e2e_mobile_latency.sh.
    """
    data = base64.b64decode(render_update_b64)
    offset = 0

    def take(count: int) -> bytes:
        nonlocal offset
        if offset + count > len(data):
            raise ValueError("truncated render update")
        chunk = data[offset : offset + count]
        offset += count
        return chunk

    if take(4) != b"GRTU":
        raise ValueError("invalid render update magic")
    version = take(1)[0]
    # The codec has no compatibility path for older versions: a layout change bumps the version byte and
    # every decoder rejects the rest rather than misreading offsets.
    if version != RENDER_UPDATE_VERSION:
        raise ValueError(f"unsupported render update version {version} (expected {RENDER_UPDATE_VERSION})")
    kind_byte = take(1)[0]
    if kind_byte != 1:
        raise ValueError(f"expected a full render frame from state, got kind {kind_byte}")
    take(2)  # reserved padding
    take(8)  # session revision
    take(8)  # base revision
    take(8)  # target revision
    take(8)  # owner epoch
    take(2)  # columns
    take(2)  # rows
    take(int.from_bytes(take(2), "little"))  # fallbackReason string
    take(2)  # cursor column
    take(2)  # cursor row
    take(1)  # cursor visible
    take(4)  # default foreground RGB
    return int.from_bytes(take(4), "little") & 0xFFFFFF  # default background RGB


def read_terminal_default_background_rgb(args: argparse.Namespace, app: dict, session_id: str) -> int | None:
    """The session's rendered default background, or None when the state carried no frame yet.

    A decode failure is deliberately not caught: it means the harness and the codec disagree about the wire
    format, which every subsequent poll would hit identically, so raising surfaces the real error instead of
    letting a bounded wait time out reporting an invented colour.
    """
    response = send("state", {"sessionID": session_id}, args, app)
    state = result(response, "terminalState", f"state {session_id}")
    render_update = state.get("renderUpdate")
    if not render_update:
        return None
    return decode_full_frame_default_background_rgb(render_update)


def format_background_rgb(rgb: int | None) -> str:
    """Renders a background colour for an assertion message, keeping "no frame" distinct from black."""
    return "no decodable frame" if rgb is None else f"#{rgb:06x}"


def assert_appearance_flip_retheme(args: argparse.Namespace, app: dict, session_id: str) -> dict:
    """Flips the terminal's light/dark appearance through the Device API and asserts the daemon re-themes
    the live session: a subsequent full render frame must carry the target variant's default background
    RGB. Deliberately cheap — one flip plus a bounded poll — and exercises the same client request path the
    harness uses everywhere else. setAppearance is not owner-gated, so a throwaway client id is fine."""
    client_id = str(uuid.uuid4()).upper()
    before_rgb = read_terminal_default_background_rgb(args, app, session_id)
    # Flip to whichever variant differs from what the terminal currently renders so the assertion observes
    # a real re-theme rather than a no-op.
    target = "light" if before_rgb == TERMINAL_BACKGROUND_RGB["dark"] else "dark"
    expected_rgb = TERMINAL_BACKGROUND_RGB[target]
    require_ok(
        send(
            "terminalControl",
            terminal_control_payload("setAppearance", session_id, clientID=client_id, appearance=target),
            args,
            app,
        ),
        f"setAppearance {target}",
    )

    observed = {"rgb": before_rgb}

    def retheme_landed():
        # The macOS daemon applies terminal colors on its io thread, so poll a fresh full frame per
        # attempt until the recolor lands (or the bounded wait elapses).
        rgb = read_terminal_default_background_rgb(args, app, session_id)
        observed["rgb"] = rgb
        return rgb == expected_rgb

    try:
        wait_for(retheme_landed, f"terminal to re-theme to {target}", timeout=15.0, interval=0.25)
    except TimeoutError as error:
        raise AssertionError(
            f"setAppearance({target}) did not re-theme the live session: "
            f"expected defaultBackgroundRGB #{expected_rgb:06x}, "
            f"observed {format_background_rgb(observed['rgb'])} (before flip {format_background_rgb(before_rgb)})"
        ) from error
    return {
        "appearance": target,
        "expectedBackgroundRGB": f"#{expected_rgb:06x}",
        "beforeBackgroundRGB": format_background_rgb(before_rgb),
    }


def wait_for_process_row(args: argparse.Namespace, app: dict, workspace_id: str, state: str) -> dict:
    # `wait_for` reports only the predicate's last value, and a predicate that returns None cannot say
    # whether the row was missing or merely in another state — two failures with completely different
    # causes. The observed rows are captured here so the timeout names which one happened.
    observed: dict = {}

    def attempt():
        workspace = workspace_overview(args, app, workspace_id)
        observed["processRows"] = [{"name": row.get("name"), "runState": row.get("runState")} for row in workspace.get("processRows") or []]
        row = find_named_row(workspace, "processRows", PROCESS_NAME)
        if row and row.get("runState") == state:
            return row
        return None

    try:
        return wait_for(attempt, f"{PROCESS_NAME} row state {state}")
    except TimeoutError as error:
        rows = observed.get("processRows")
        detail = "no processRows at all" if rows == [] else f"processRows={json.dumps(rows, sort_keys=True)}"
        raise TimeoutError(f"{error} ({detail})") from None


def wait_for_agent_row(args: argparse.Namespace, app: dict, workspace_id: str, state: str) -> dict:
    # Same ambiguity as wait_for_process_row: distinguish a missing row from a row in another state.
    observed: dict = {}

    def attempt():
        workspace = workspace_overview(args, app, workspace_id)
        observed["codingAgentRows"] = [
            {"name": row.get("name"), "runState": row.get("runState")} for row in workspace.get("codingAgentRows") or []
        ]
        row = find_named_row(workspace, "codingAgentRows", AGENT_NAME)
        if row and row.get("runState") == state:
            return row
        return None

    try:
        return wait_for(attempt, f"{AGENT_NAME} row state {state}")
    except TimeoutError as error:
        rows = observed.get("codingAgentRows")
        detail = "no codingAgentRows at all" if rows == [] else f"codingAgentRows={json.dumps(rows, sort_keys=True)}"
        raise TimeoutError(f"{error} ({detail})") from None


def require_config_rows(args: argparse.Namespace, app: dict, workspace_id: str) -> tuple[dict, dict]:
    workspace = workspace_overview(args, app, workspace_id)
    process_row = find_named_row(workspace, "processRows", PROCESS_NAME)
    agent_row = find_named_row(workspace, "codingAgentRows", AGENT_NAME)
    if not process_row or not agent_row:
        raise AssertionError(f"workspace missing parity rows: {json.dumps(workspace, indent=2, sort_keys=True)}")
    return process_row, agent_row


def run(args: argparse.Namespace) -> dict:
    args._request_timings = []
    app = client_app(args)
    project_dir = str(Path(args.project_dir))
    overview_initial = current_overview(args, app)
    cleanup_prior_e2e_projects(args, app, overview_initial)
    overview_initial = current_overview(args, app)

    created_project = mutation(
        send("createProject", {"projectDir": project_dir, "gitURL": None}, args, app),
        "createProject",
    )
    project_id = created_project.get("projectID")
    default_workspace_id = created_project.get("workspaceID")
    if not project_id or not default_workspace_id:
        raise AssertionError(f"createProject did not return project and default workspace IDs: {json.dumps(created_project, indent=2, sort_keys=True)}")

    result(
        send("workspaceCreateOptions", {"projectID": project_id}, args, app),
        "workspaceCreateOptions",
        "workspaceCreateOptions",
    )

    workspace_title = f"Device API Parity {args.label}"
    workspace_branch = f"device-api-parity-{args.label}"
    created_workspace = mutation(
        send(
            "createWorkspace",
            {
                "projectID": project_id,
                "title": workspace_title,
                "branch": workspace_branch,
                "baseBranch": None,
                "directoryName": workspace_branch,
                "allowExistingBranchReuse": False,
            },
            args,
            app,
        ),
        "createWorkspace",
    )
    workspace_id = created_workspace.get("workspaceID")
    if not workspace_id:
        raise AssertionError(f"createWorkspace did not return workspaceID: {json.dumps(created_workspace, indent=2, sort_keys=True)}")
    require_config_rows(args, app, workspace_id)

    terminal_open_started = time.perf_counter()
    terminal_mutation = mutation(send("openWorkspaceTerminal", {"workspaceID": workspace_id}, args, app), "openWorkspaceTerminal")
    terminal_open_request_ms = (time.perf_counter() - terminal_open_started) * 1000
    terminal_session_id = terminal_mutation.get("sessionID")
    if not terminal_session_id:
        raise AssertionError(f"openWorkspaceTerminal did not return sessionID: {json.dumps(terminal_mutation, indent=2, sort_keys=True)}")
    terminal_ready_started = time.perf_counter()
    terminal_ready_state = wait_for_terminal_state(args, app, terminal_session_id)
    terminal_ready_wait_ms = (time.perf_counter() - terminal_ready_started) * 1000
    terminal_latency_summary = run_terminal_latency_probe(
        args,
        app,
        terminal_session_id,
        terminal_open_request_ms,
        terminal_ready_wait_ms,
        terminal_ready_state,
    )
    if args.terminal_latency_json:
        latency_output_path = Path(args.terminal_latency_json)
        latency_output_path.parent.mkdir(parents=True, exist_ok=True)
        latency_output_path.write_text(json.dumps(terminal_latency_summary, indent=2, sort_keys=True) + "\n")
    # Live re-theming: flip the terminal's light/dark appearance and confirm the daemon re-themes the
    # already-rendering session (decoded render-frame background switches to the target variant).
    appearance_flip = assert_appearance_flip_retheme(args, app, terminal_session_id)
    # Agent send/tail round trip: one-shot input lands without any attach/owner handshake and
    # the rendered tail echoes it back.
    tail_marker = f"parity-send-tail-{uuid.uuid4().hex[:8]}"
    require_ok(
        send(
            "sendTerminalInput",
            {"sessionID": terminal_session_id, "text": f"echo {tail_marker}", "appendNewline": True},
            args,
            app,
        ),
        "sendTerminalInput",
    )

    def tail_shows_marker():
        response = send("tailTerminalOutput", {"sessionID": terminal_session_id, "lines": 50}, args, app)
        text = result(response, "terminalOutput", "tailTerminalOutput").get("text") or ""
        # The echoed command line also contains the marker, so require an output line that is
        # exactly the marker.
        return any(line.strip() == tail_marker for line in text.splitlines())

    wait_for(tail_shows_marker, f"tailTerminalOutput to show '{tail_marker}'", timeout=30.0)

    rename_title = "parity-renamed-shell"
    renamed_overview = overview_from_mutation(
        send(
            "renameTerminalSession",
            {"workspaceID": workspace_id, "sessionID": terminal_session_id, "title": rename_title},
            args,
            app,
        ),
        "renameTerminalSession",
    )
    renamed_workspace = find_workspace(renamed_overview, workspace_id)
    if not renamed_workspace or not find_named_row(renamed_workspace, "terminalRows", rename_title):
        raise AssertionError(
            f"renameTerminalSession overview did not show renamed terminal row: {json.dumps(renamed_overview, indent=2, sort_keys=True)}"
        )
    mutation(
        send("stopWorkspaceTerminal", {"workspaceID": workspace_id, "sessionID": terminal_session_id}, args, app),
        "stopWorkspaceTerminal",
    )

    mutation(
        send("runWorkspaceProcess", {"workspaceID": workspace_id, "processKey": PROCESS_NAME, "processTemplateID": None}, args, app),
        "runWorkspaceProcess",
    )
    process_row = wait_for_process_row(args, app, workspace_id, "running")
    mutation(
        send(
            "restartWorkspaceProcess",
            {
                "workspaceID": workspace_id,
                "processID": process_row.get("processID"),
                "processKey": PROCESS_NAME,
                "processTemplateID": process_row.get("templateID"),
            },
            args,
            app,
        ),
        "restartWorkspaceProcess",
    )
    process_row = wait_for_process_row(args, app, workspace_id, "running")
    process_id = process_row.get("processID")
    mutation(
        send(
            "stopWorkspaceProcess",
            {
                "workspaceID": workspace_id,
                "processID": process_row.get("processID"),
                "processKey": PROCESS_NAME,
                "processTemplateID": process_row.get("templateID"),
            },
            args,
            app,
        ),
        "stopWorkspaceProcess",
    )
    wait_for_process_row(args, app, workspace_id, "notStarted")

    agent_run = mutation(
        send("runCodingAgent", {"workspaceID": workspace_id, "agentName": AGENT_NAME, "agentLauncherID": None}, args, app),
        "runCodingAgent",
    )
    agent_session_id = agent_run.get("sessionID")
    agent_row = wait_for_agent_row(args, app, workspace_id, "running")
    agent_id = agent_row.get("agentID")

    # Orchestration surface (`spaces agent … --device`): the running coding agent registered a Spaces
    # agent row, so it shows in listAgentSessions; annotateAgentSession sets and persists its note, and
    # a later stopCodingAgent is the remote kill. spawnAgentSession's supported-agent hook gate rejects
    # an unsupported command remotely — a negative check needing no installed hooks.
    listed_rows = result(
        send("listAgentSessions", {"sessionID": agent_session_id}, args, app), "agentSessions", "listAgentSessions"
    ).get("rows") or []
    if not any(row.get("terminalSessionID") == agent_session_id for row in listed_rows):
        raise AssertionError(f"listAgentSessions did not include {agent_session_id}: {json.dumps(listed_rows, indent=2, sort_keys=True)}")
    annotated_rows = result(
        send("annotateAgentSession", {"sessionID": agent_session_id, "note": "parity review"}, args, app),
        "agentSessions",
        "annotateAgentSession",
    ).get("rows") or []
    if not annotated_rows or annotated_rows[0].get("note") != "parity review":
        raise AssertionError(f"annotateAgentSession did not persist note: {json.dumps(annotated_rows, indent=2, sort_keys=True)}")
    reread_rows = result(
        send("listAgentSessions", {"sessionID": agent_session_id}, args, app), "agentSessions", "listAgentSessions"
    ).get("rows") or []
    if not any(row.get("note") == "parity review" for row in reread_rows):
        raise AssertionError(f"listAgentSessions did not carry the persisted note: {json.dumps(reread_rows, indent=2, sort_keys=True)}")
    spawn_rejected = send("spawnAgentSession", {"workspaceID": workspace_id, "command": "ls -la"}, args, app)
    if spawn_rejected.get("ok") is not False:
        raise AssertionError(f"spawnAgentSession accepted an unsupported command: {json.dumps(spawn_rejected, indent=2, sort_keys=True)}")

    mutation(
        send(
            "restartCodingAgent",
            {
                "workspaceID": workspace_id,
                "agentID": agent_row.get("agentID"),
                "agentName": AGENT_NAME,
                "agentLauncherID": agent_row.get("launcherID"),
            },
            args,
            app,
        ),
        "restartCodingAgent",
    )
    agent_row = wait_for_agent_row(args, app, workspace_id, "running")
    mutation(
        send(
            "stopCodingAgent",
            {
                "workspaceID": workspace_id,
                "agentID": agent_row.get("agentID"),
                "agentName": AGENT_NAME,
                "agentLauncherID": agent_row.get("launcherID"),
            },
            args,
            app,
        ),
        "stopCodingAgent",
    )
    wait_for_agent_row(args, app, workspace_id, "notStarted")

    overview_final = current_overview(args, app)
    final_workspace = find_workspace(overview_final, workspace_id) or {}
    remote_web_port = next(
        (port for port in final_workspace.get("assignedPorts") or [] if port.get("name") == "web"),
        {},
    )
    remote_web_session = next(
        (session for session in ((final_workspace.get("config") or {}).get("resolvedBrowserSessions") or []) if session.get("name") == REMOTE_WEB_SESSION_NAME),
        {},
    )
    summary = {
        "label": args.label,
        "projectDir": project_dir,
        "initialProjectCount": len(overview_initial.get("projects") or []),
        "projectID": project_id,
        "defaultWorkspaceID": default_workspace_id,
        "workspaceID": workspace_id,
        "terminalSessionID": terminal_session_id,
        "terminalAppearanceFlip": appearance_flip,
        "processID": process_id,
        "agentID": agent_id,
        "agentSessionID": agent_session_id,
        "remoteWebServicePort": remote_web_port.get("port"),
        "remoteWebServiceURL": remote_web_port.get("url"),
        "remoteWebBrowserURL": remote_web_session.get("url"),
        "finalProjectCount": len(overview_final.get("projects") or []),
    }
    if args.result_json:
        output_path = Path(args.result_json)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    return summary


def main() -> int:
    args = parse_args()
    try:
        print(json.dumps(run(args), indent=2, sort_keys=True))
        return 0
    except Exception as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
