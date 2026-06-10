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

    public func startSpacesDaemon(host: ComputeHostRecord, authToken: String, timeout: TimeInterval = 30) throws -> ComputeHostBootstrapOutcome {
        let token = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ComputeHostBootstrapError.missingAuthToken }

        let output = try runCommand(Self.sshCommand(host: host, authToken: token, selectsAvailablePort: false), timeout)
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

        let output = try runCommand(Self.sshCommand(host: prepared.host, authToken: token, selectsAvailablePort: true), timeout)
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

    static func sshCommand(host: ComputeHostRecord, authToken: String, selectsAvailablePort: Bool) -> [String] {
        var command = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=accept-new"]
        if let port = host.sshPort { command.append(contentsOf: ["-p", String(port)]) }
        command.append(sshDestination(host: host))
        command.append(remoteStartScript(host: host, authToken: authToken, selectsAvailablePort: selectsAvailablePort))
        return command
    }

    static func remoteStartScript(host: ComputeHostRecord, authToken: String, selectsAvailablePort: Bool = false) -> String {
        let hostID = safePathComponent(host.id)
        let workspaceRoot = shellSingleQuoted(host.workspaceRoot)
        let port = host.daemonEndpoint.port
        let token = shellSingleQuoted(authToken)
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
            mkdir -p "${profile_root}" "${runtime_root}" "${workspace_root}"
            spacesd_path="$(command -v spacesd || true)"
            if [ -z "${spacesd_path}" ]; then
              echo "spacesd executable not found on remote host PATH." >&2
              exit 127
            fi
            fingerprint="$(SPACES_DB_PATH="${db_path}" SPACES_RUNTIME_DIR="${runtime_root}" SPACESD_PRINT_CERTIFICATE_FINGERPRINT=1 "${spacesd_path}")"
            if [ -z "${fingerprint}" ]; then
              echo "spacesd did not print a certificate fingerprint." >&2
              exit 1
            fi
            \(portSelectionScript)
            log_path="${profile_root}/spacesd-${selected_port}.log"
            daemon_pid=""
            if ! { command -v lsof >/dev/null 2>&1 && lsof -nPiTCP:${selected_port} -sTCP:LISTEN >/dev/null 2>&1; }; then
              nohup env SPACES_DB_PATH="${db_path}" SPACES_RUNTIME_DIR="${runtime_root}" SPACESD_LISTEN_PORT="${selected_port}" SPACESD_AUTH_TOKEN=\(token) "${spacesd_path}" >>"${log_path}" 2>&1 &
              daemon_pid="$!"
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
