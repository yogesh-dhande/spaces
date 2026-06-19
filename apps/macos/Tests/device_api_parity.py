#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
import time
import uuid
from pathlib import Path


PROCESS_NAME = "parity-process"
AGENT_NAME = "parity-agent"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the shared Spaces Device API local/remote parity flow.")
    parser.add_argument("--spacese2e", required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--transport-key", required=True)
    parser.add_argument("--auth-token", required=True)
    parser.add_argument("--project-dir", required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--result-json")
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
    command_args = [
        args.spacese2e,
        "mobile-request",
        "--host",
        args.host,
        "--port",
        str(args.port),
        "--transport-key",
        args.transport_key,
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
        return json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(
            f"invalid JSON response for {command}: {error}\nstdout={completed.stdout!r}\nstderr={completed.stderr!r}"
        ) from error


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
    overview = current_overview(args, app)
    workspace = find_workspace(overview, workspace_id)
    if not workspace:
        raise AssertionError(f"overview did not include workspace {workspace_id}: {json.dumps(overview, indent=2, sort_keys=True)}")
    return workspace


def wait_for_terminal_state(args: argparse.Namespace, app: dict, session_id: str) -> dict:
    def attempt():
        response = send("state", {"sessionID": session_id}, args, app)
        if response.get("ok") is not True:
            return None
        return result(response, "terminalState", f"state {session_id}")

    return wait_for(attempt, f"terminal state {session_id}")


def wait_for_process_row(args: argparse.Namespace, app: dict, workspace_id: str, state: str) -> dict:
    def attempt():
        workspace = workspace_overview(args, app, workspace_id)
        row = find_named_row(workspace, "processRows", PROCESS_NAME)
        if row and row.get("runState") == state:
            return row
        return None

    return wait_for(attempt, f"{PROCESS_NAME} row state {state}")


def wait_for_agent_row(args: argparse.Namespace, app: dict, workspace_id: str, state: str) -> dict:
    def attempt():
        workspace = workspace_overview(args, app, workspace_id)
        row = find_named_row(workspace, "codingAgentRows", AGENT_NAME)
        if row and row.get("runState") == state:
            return row
        return None

    return wait_for(attempt, f"{AGENT_NAME} row state {state}")


def require_config_rows(args: argparse.Namespace, app: dict, workspace_id: str) -> tuple[dict, dict]:
    workspace = workspace_overview(args, app, workspace_id)
    process_row = find_named_row(workspace, "processRows", PROCESS_NAME)
    agent_row = find_named_row(workspace, "codingAgentRows", AGENT_NAME)
    if not process_row or not agent_row:
        raise AssertionError(f"workspace missing parity rows: {json.dumps(workspace, indent=2, sort_keys=True)}")
    return process_row, agent_row


def run(args: argparse.Namespace) -> dict:
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
                "targetBranch": None,
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

    terminal_mutation = mutation(send("openWorkspaceTerminal", {"workspaceID": workspace_id}, args, app), "openWorkspaceTerminal")
    terminal_session_id = terminal_mutation.get("sessionID")
    if not terminal_session_id:
        raise AssertionError(f"openWorkspaceTerminal did not return sessionID: {json.dumps(terminal_mutation, indent=2, sort_keys=True)}")
    wait_for_terminal_state(args, app, terminal_session_id)
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
    summary = {
        "label": args.label,
        "projectDir": project_dir,
        "initialProjectCount": len(overview_initial.get("projects") or []),
        "projectID": project_id,
        "defaultWorkspaceID": default_workspace_id,
        "workspaceID": workspace_id,
        "terminalSessionID": terminal_session_id,
        "processID": process_id,
        "agentID": agent_id,
        "agentSessionID": agent_session_id,
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
