import Foundation

public struct ComputeHostBootstrapOutcome: Sendable, Equatable {
    public let certificateFingerprint: String
    public let workspaceRoot: String
    public let daemonHost: String
    public let daemonPort: Int
    public let processID: Int?
    public let logPath: String

    public init(
        certificateFingerprint: String, workspaceRoot: String = "", daemonHost: String = "", daemonPort: Int = 0, processID: Int?, logPath: String
    ) {
        self.certificateFingerprint = certificateFingerprint
        self.workspaceRoot = workspaceRoot
        self.daemonHost = daemonHost
        self.daemonPort = daemonPort
        self.processID = processID
        self.logPath = logPath
    }
}

public struct ComputeHostBootstrapResult: Sendable, Equatable {
    public let host: ComputeHostRecord
    public let authToken: String
    public let outcome: ComputeHostBootstrapOutcome

    public init(host: ComputeHostRecord, authToken: String, outcome: ComputeHostBootstrapOutcome) {
        self.host = host
        self.authToken = authToken
        self.outcome = outcome
    }
}

public enum ComputeHostBootstrapError: LocalizedError, Equatable {
    case missingAuthToken
    case sshCommandFailed(String)
    case sshCommandTimedOut(TimeInterval)
    case invalidBootstrapOutput(String)

    public var errorDescription: String? {
        switch self {
        case .missingAuthToken: "A spacesd auth token is required to start a remote compute host."
        case .sshCommandFailed(let message): message.isEmpty ? "Remote spacesd bootstrap failed over SSH." : message
        case .sshCommandTimedOut(let timeout): "Timed out after \(Self.format(timeout)) seconds while starting remote spacesd over SSH."
        case .invalidBootstrapOutput(let output): "Remote spacesd bootstrap did not return a certificate fingerprint. Output: \(output)"
        }
    }

    private static func format(_ value: TimeInterval) -> String { value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value) }
}

public struct ComputeHostBootstrapper {
    public typealias CommandRunner = @Sendable ([String], TimeInterval) throws -> String

    private let runCommand: CommandRunner

    public init() { self.runCommand = Self.defaultRunCommand }

    init(runCommand: @escaping CommandRunner) { self.runCommand = runCommand }

    public func startSpacesDaemon(host: ComputeHostRecord, authToken: String, timeout: TimeInterval = 30, cleanExistingProfile: Bool = false) throws
        -> ComputeHostBootstrapOutcome
    {
        let token = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ComputeHostBootstrapError.missingAuthToken }

        let output = try runCommand(
            Self.sshCommand(host: host, authToken: token, selectsAvailablePort: false, cleanExistingProfile: cleanExistingProfile), timeout)
        let parsed = try Self.parseBootstrapOutput(output)
        return ComputeHostBootstrapOutcome(
            certificateFingerprint: parsed.certificateFingerprint,
            workspaceRoot: parsed.workspaceRoot.isEmpty ? host.workspaceRoot : parsed.workspaceRoot,
            daemonHost: parsed.daemonHost.isEmpty ? host.daemonEndpoint.host : parsed.daemonHost,
            daemonPort: parsed.daemonPort == 0 ? host.daemonEndpoint.port : parsed.daemonPort, processID: parsed.processID, logPath: parsed.logPath)
    }

    public func startSpacesDaemon(
        draft: ComputeHostDraft, resolvedSSH: SSHResolvedConfiguration? = nil, existingHost: ComputeHostRecord? = nil, authToken: String,
        timeout: TimeInterval = 30
    ) throws -> ComputeHostBootstrapResult {
        let prepared = try ComputeHostDraftBuilder.prepare(draft: draft, resolvedSSH: resolvedSSH, existing: existingHost, authToken: authToken)
        let token = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ComputeHostBootstrapError.missingAuthToken }

        let output = try runCommand(
            Self.sshCommand(host: prepared.host, authToken: token, selectsAvailablePort: true, cleanExistingProfile: false), timeout)
        let outcome = try Self.parseBootstrapOutput(output)
        var host = prepared.host
        host.workspaceRoot = outcome.workspaceRoot.isEmpty ? host.workspaceRoot : outcome.workspaceRoot
        host.daemonEndpoint = SpacesDaemonEndpoint(
            host: outcome.daemonHost.isEmpty ? host.daemonEndpoint.host : outcome.daemonHost,
            port: outcome.daemonPort == 0 ? host.daemonEndpoint.port : outcome.daemonPort, certificateFingerprint: outcome.certificateFingerprint)
        let normalizedOutcome = ComputeHostBootstrapOutcome(
            certificateFingerprint: outcome.certificateFingerprint, workspaceRoot: host.workspaceRoot, daemonHost: host.daemonEndpoint.host,
            daemonPort: host.daemonEndpoint.port, processID: outcome.processID, logPath: outcome.logPath)
        return ComputeHostBootstrapResult(host: host, authToken: token, outcome: normalizedOutcome)
    }

    static func sshCommand(host: ComputeHostRecord, authToken: String, selectsAvailablePort: Bool, cleanExistingProfile: Bool = false) -> [String] {
        var command = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=accept-new"]
        if let port = host.sshPort { command.append(contentsOf: ["-p", String(port)]) }
        command.append(sshDestination(host: host))
        command.append(
            remoteStartScript(
                host: host, authToken: authToken, selectsAvailablePort: selectsAvailablePort, cleanExistingProfile: cleanExistingProfile))
        return command
    }

    static func remoteStartScript(host: ComputeHostRecord, authToken: String, selectsAvailablePort: Bool = false, cleanExistingProfile: Bool = false)
        -> String
    {
        let hostID = safePathComponent(host.id)
        let workspaceRoot = shellSingleQuoted(host.workspaceRoot)
        let port = host.daemonEndpoint.port
        let token = shellSingleQuoted(authToken)
        let cleanProfileScript: String
        if cleanExistingProfile {
            cleanProfileScript = """
                lsof_path="$(command -v lsof || true)"
                if [ -z "${lsof_path}" ]; then
                  echo "lsof executable not found on remote host PATH." >&2
                  exit 127
                fi
                port_pids="$("${lsof_path}" -tiTCP:${requested_port} -sTCP:LISTEN 2>/dev/null || true)"
                if [ -n "${port_pids}" ]; then
                  for pid in ${port_pids}; do
                    kill "${pid}" >/dev/null 2>&1 || true
                  done
                  clean_attempt=0
                  while [ "${clean_attempt}" -lt 40 ]; do
                    if ! "${lsof_path}" -nPiTCP:${requested_port} -sTCP:LISTEN >/dev/null 2>&1; then
                      break
                    fi
                    clean_attempt=$((clean_attempt + 1))
                    sleep 0.25
                  done
                  if "${lsof_path}" -nPiTCP:${requested_port} -sTCP:LISTEN >/dev/null 2>&1; then
                    for pid in $("${lsof_path}" -tiTCP:${requested_port} -sTCP:LISTEN 2>/dev/null || true); do
                      kill -9 "${pid}" >/dev/null 2>&1 || true
                    done
                  fi
                  clean_attempt=0
                  while [ "${clean_attempt}" -lt 20 ]; do
                    if ! "${lsof_path}" -nPiTCP:${requested_port} -sTCP:LISTEN >/dev/null 2>&1; then
                      break
                    fi
                    clean_attempt=$((clean_attempt + 1))
                    sleep 0.25
                  done
                  if "${lsof_path}" -nPiTCP:${requested_port} -sTCP:LISTEN >/dev/null 2>&1; then
                    echo "remote E2E cleanup could not free spacesd port ${requested_port}." >&2
                    exit 1
                  fi
                fi
                rm -rf "${profile_root}"
                """
        } else {
            cleanProfileScript = ""
        }
        let portSelectionScript: String
        if selectsAvailablePort {
            portSelectionScript = """
                lsof_path="$(command -v lsof || true)"
                if [ -z "${lsof_path}" ]; then
                  echo "lsof executable not found on remote host PATH." >&2
                  exit 127
                fi
                selected_port=""
                port_candidate="${requested_port}"
                last_port=$((requested_port + 9))
                while [ "${port_candidate}" -le "${last_port}" ]; do
                  if ! "${lsof_path}" -nPiTCP:${port_candidate} -sTCP:LISTEN >/dev/null 2>&1; then
                    selected_port="${port_candidate}"
                    break
                  fi
                  port_candidate=$((port_candidate + 1))
                done
                if [ -z "${selected_port}" ]; then
                  echo "No available spacesd port found in ${requested_port}-${last_port}." >&2
                  exit 1
                fi
                """
        } else {
            portSelectionScript = """
                selected_port="${requested_port}"
                """
        }

        return """
            set -eu
            PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
            profile_root="${HOME}/.spaces/compute-hosts/\(hostID)"
            runtime_root="${profile_root}/runtime"
            db_path="${profile_root}/spaces.db"
            requested_port=\(port)
            workspace_root_input=\(workspaceRoot)
            case "${workspace_root_input}" in
              '$HOME'|'$HOME/'*) workspace_root="${HOME}${workspace_root_input#\\$HOME}" ;;
              '~'|'~/'*) workspace_root="${HOME}${workspace_root_input#\\~}" ;;
              /*) workspace_root="${workspace_root_input}" ;;
              *) workspace_root="${HOME}/${workspace_root_input}" ;;
            esac
            \(cleanProfileScript)
            mkdir -p "${profile_root}" "${runtime_root}" "${workspace_root}" "${profile_root}/bin"
            cat >"${profile_root}/bin/spaces" <<'SPACES_REMOTE_HELPER'
            #!/usr/bin/env bash
            set -euo pipefail

            usage() {
              echo "usage: spaces agent signal --workspace <id> --session <terminal-session-id> <init|start|waiting|done|exit>" >&2
              exit 64
            }

            if [ "${1:-}" != "agent" ] || [ "${2:-}" != "signal" ]; then
              usage
            fi
            shift 2

            workspace_id=""
            session_id=""
            event_type=""
            while [ "$#" -gt 0 ]; do
              case "${1}" in
                --workspace)
                  [ "$#" -ge 2 ] || usage
                  workspace_id="${2}"
                  shift 2
                  ;;
                --workspace=*)
                  workspace_id="${1#--workspace=}"
                  shift
                  ;;
                --session)
                  [ "$#" -ge 2 ] || usage
                  session_id="${2}"
                  shift 2
                  ;;
                --session=*)
                  session_id="${1#--session=}"
                  shift
                  ;;
                init|start|waiting|done|exit)
                  [ -z "${event_type}" ] || usage
                  event_type="${1}"
                  shift
                  ;;
                *)
                  usage
                  ;;
              esac
            done
            [ -n "${workspace_id}" ] || usage
            [ -n "${session_id}" ] || usage
            [ -n "${event_type}" ] || usage

            python3 - "${workspace_id}" "${session_id}" "${event_type}" <<'PY'
            import datetime
            import json
            import os
            import socket
            import sys
            import uuid

            workspace_id, session_id, event_type = [argument.strip() for argument in sys.argv[1:4]]
            allowed = {"init", "start", "waiting", "done", "exit"}
            if event_type not in allowed:
                print(f"unsupported agent signal event: {event_type}", file=sys.stderr)
                sys.exit(64)

            runtime_root = os.environ.get("SPACES_RUNTIME_DIR", "").strip()
            if not runtime_root:
                print("SPACES_RUNTIME_DIR is required for remote spaces agent signal.", file=sys.stderr)
                sys.exit(64)

            def socket_path():
                override = os.environ.get("SPACESD_SERVICE_SOCKET", "").strip()
                if override:
                    return override
                terminal_root = os.path.abspath(os.path.join(runtime_root, "terminal"))
                value = 5381
                for byte in terminal_root.encode("utf-8"):
                    value = (((value << 5) + value) + byte) & 0xFFFFFFFFFFFFFFFF
                return f"/tmp/spaces-terminal-sockets/service-{value:016x}.sock"

            def optional_env(name):
                value = os.environ.get(name, "").strip()
                return value or None

            created_at = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
            event = {
                "id": str(uuid.uuid4()),
                "sessionID": session_id,
                "workspaceID": workspace_id,
                "workspacePath": optional_env("SPACES_WORKSPACE_DIR"),
                "type": event_type,
                "provider": "spaces",
                "label": optional_env("SPACES_AGENT_LABEL"),
                "terminalTrackingID": session_id,
                "terminalNativeID": session_id,
                "codexThreadID": optional_env("CODEX_THREAD_ID"),
                "environmentKeys": sorted(os.environ.keys()),
                "createdAt": created_at,
            }
            request = {"command": "agentSignal", "sessionID": session_id, "agentSignal": event}

            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(5)
            try:
                sock.connect(socket_path())
                sock.sendall(json.dumps(request, separators=(",", ":")).encode("utf-8") + b"\\n")
                sock.shutdown(socket.SHUT_WR)
                data = bytearray()
                while True:
                    chunk = sock.recv(4096)
                    if not chunk:
                        break
                    data.extend(chunk)
                    if b"\\n" in chunk:
                        break
            finally:
                sock.close()

            line = bytes(data).split(b"\\n", 1)[0]
            response = json.loads(line.decode("utf-8"))
            if not response.get("ok"):
                print(response.get("message") or "remote spacesd rejected agent signal", file=sys.stderr)
                sys.exit(1)

            print(f"Agent {event_type}: queued remote signal\\tsession={session_id}")
            PY
            SPACES_REMOTE_HELPER
            chmod +x "${profile_root}/bin/spaces"
            spacesd_path="$(command -v spacesd || true)"
            if [ -z "${spacesd_path}" ]; then
              echo "spacesd executable not found on remote host PATH." >&2
              exit 127
            fi
            spacesd_bin_dir="$(python3 -c 'import os, sys; print(os.path.dirname(os.path.realpath(sys.argv[1])))' "${spacesd_path}" 2>/dev/null || dirname "${spacesd_path}")"
            PATH="${profile_root}/bin:${spacesd_bin_dir}:$PATH"
            fingerprint="$(SPACES_DB_PATH="${db_path}" SPACES_RUNTIME_DIR="${runtime_root}" SPACESD_PRINT_CERTIFICATE_FINGERPRINT=1 "${spacesd_path}")"
            if [ -z "${fingerprint}" ]; then
              echo "spacesd did not print a certificate fingerprint." >&2
              exit 1
            fi
            \(portSelectionScript)
            log_path="${profile_root}/spacesd-${selected_port}.log"
            daemon_pid=""
            if [ -z "${lsof_path:-}" ]; then
              lsof_path="$(command -v lsof || true)"
            fi
            if ! { [ -n "${lsof_path}" ] && "${lsof_path}" -nPiTCP:${selected_port} -sTCP:LISTEN >/dev/null 2>&1; }; then
              nohup env PATH="${PATH}" SPACES_DB_PATH="${db_path}" SPACES_RUNTIME_DIR="${runtime_root}" SPACESD_LISTEN_PORT="${selected_port}" SPACESD_AUTH_TOKEN=\(token) "${spacesd_path}" >>"${log_path}" 2>&1 &
              daemon_pid="$!"
            fi
            if [ -n "${lsof_path}" ]; then
              ready_attempt=0
              listener_ready=0
              while [ "${ready_attempt}" -lt 100 ]; do
                if "${lsof_path}" -nPiTCP:${selected_port} -sTCP:LISTEN >/dev/null 2>&1; then
                  listener_ready=1
                  break
                fi
                ready_attempt=$((ready_attempt + 1))
                sleep 0.2
              done
              if [ "${listener_ready}" != "1" ]; then
                echo "spacesd did not start listening on port ${selected_port}." >&2
                if [ -f "${log_path}" ]; then tail -n 40 "${log_path}" >&2 || true; fi
                exit 1
              fi
            else
              sleep 1
            fi
            printf 'fingerprint=%s\\n' "${fingerprint}"
            printf 'workspace_root=%s\\n' "${workspace_root}"
            printf 'port=%s\\n' "${selected_port}"
            printf 'pid=%s\\n' "${daemon_pid}"
            printf 'log=%s\\n' "${log_path}"
            """
    }

    static func parseBootstrapOutput(_ output: String) throws -> ComputeHostBootstrapOutcome {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            values[String(parts[0])] = String(parts[1])
        }
        guard let fingerprint = values["fingerprint"]?.trimmingCharacters(in: .whitespacesAndNewlines), !fingerprint.isEmpty else {
            throw ComputeHostBootstrapError.invalidBootstrapOutput(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let pid = values["pid"].flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let port = values["port"].flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        return ComputeHostBootstrapOutcome(
            certificateFingerprint: fingerprint, workspaceRoot: values["workspace_root"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            daemonHost: values["daemon_host"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", daemonPort: port, processID: pid,
            logPath: values["log"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    private static func sshDestination(host: ComputeHostRecord) -> String {
        let sshHost = host.sshHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sshHost.contains("@"), let user = host.sshUser?.trimmingCharacters(in: .whitespacesAndNewlines), !user.isEmpty else { return sshHost }
        return "\(user)@\(sshHost)"
    }

    private static func safePathComponent(_ value: String) -> String {
        let lowercased = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var scalars: [UnicodeScalar] = []
        var lastWasSeparator = false
        for scalar in lowercased.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                scalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                scalars.append("-")
                lastWasSeparator = true
            }
        }
        let result = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? "host" : result
    }

    private static func shellSingleQuoted(_ value: String) -> String { "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'" }

    private static func defaultRunCommand(_ command: [String], timeout: TimeInterval) throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.standardOutput = output
        process.standardError = error
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            throw ComputeHostBootstrapError.sshCommandTimedOut(timeout)
        }

        let outputText = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorText = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let message = [errorText, outputText].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(
                separator: "\n")
            throw ComputeHostBootstrapError.sshCommandFailed(message)
        }
        return outputText
    }
}
