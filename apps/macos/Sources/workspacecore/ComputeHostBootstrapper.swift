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
    public typealias CommandRunner = @Sendable ([String], String, TimeInterval) throws -> String
    public typealias ArtifactManifestProvider = @Sendable () throws -> RemoteSpacesArtifactManifest

    private static let managedArtifactInstallTimeout: TimeInterval = 300

    private let runCommand: CommandRunner
    private let artifactManifestProvider: ArtifactManifestProvider

    public init() {
        self.runCommand = Self.defaultRunCommand
        self.artifactManifestProvider = Self.defaultArtifactManifestProvider
    }

    public init(artifactManifestProvider: @escaping ArtifactManifestProvider) {
        self.runCommand = Self.defaultRunCommand
        self.artifactManifestProvider = artifactManifestProvider
    }

    init(runCommand: @escaping CommandRunner, artifactManifestProvider: @escaping ArtifactManifestProvider = Self.defaultArtifactManifestProvider) {
        self.runCommand = runCommand
        self.artifactManifestProvider = artifactManifestProvider
    }

    public func startSpacesDaemon(host: ComputeHostRecord, authToken: String, timeout: TimeInterval = 30, cleanExistingProfile: Bool = false) throws
        -> ComputeHostBootstrapOutcome
    {
        let token = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ComputeHostBootstrapError.missingAuthToken }

        let artifact = try prepareManagedArtifact(host: host, timeout: timeout, selectsAvailablePort: false)
        let parsed = try runRemoteStartScript(
            host: host, authToken: token, artifact: artifact, selectsAvailablePort: false, cleanExistingProfile: cleanExistingProfile,
            timeout: max(timeout, Self.managedArtifactInstallTimeout))
        return ComputeHostBootstrapOutcome(
            certificateFingerprint: parsed.certificateFingerprint,
            workspaceRoot: parsed.workspaceRoot.isEmpty ? host.workspaceRoot : parsed.workspaceRoot,
            daemonHost: parsed.daemonHost.isEmpty ? host.daemonEndpoint.host : parsed.daemonHost,
            daemonPort: parsed.daemonPort == 0 ? host.daemonEndpoint.port : parsed.daemonPort, processID: parsed.processID, logPath: parsed.logPath)
    }

    public func upgradeManagedSpacesDaemon(host: ComputeHostRecord, authToken: String, timeout: TimeInterval = 30) throws
        -> ComputeHostBootstrapOutcome
    {
        let token = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ComputeHostBootstrapError.missingAuthToken }

        let artifact = try prepareManagedArtifact(host: host, timeout: timeout, selectsAvailablePort: false)
        let parsed = try runRemoteStartScript(
            host: host, authToken: token, artifact: artifact, selectsAvailablePort: false, cleanExistingProfile: false,
            timeout: max(timeout, Self.managedArtifactInstallTimeout))
        return ComputeHostBootstrapOutcome(
            certificateFingerprint: parsed.certificateFingerprint,
            workspaceRoot: parsed.workspaceRoot.isEmpty ? host.workspaceRoot : parsed.workspaceRoot,
            daemonHost: parsed.daemonHost.isEmpty ? host.daemonEndpoint.host : parsed.daemonHost,
            daemonPort: parsed.daemonPort == 0 ? host.daemonEndpoint.port : parsed.daemonPort, processID: parsed.processID, logPath: parsed.logPath)
    }

    public func uninstallManagedSpacesDaemon(host: ComputeHostRecord, timeout: TimeInterval = 30) throws {
        do { _ = try runCommand(Self.sshScriptCommand(host: host), Self.remoteUninstallScript(host: host), timeout) } catch {
            let parsed = Self.parseSetupFailure(error)
            throw setupError(host: host, failedCheck: parsed.checkID, command: parsed.command, detail: parsed.detail, fixHint: parsed.fixHint)
        }
    }

    public func startSpacesDaemon(
        draft: ComputeHostDraft, resolvedSSH: SSHResolvedConfiguration? = nil, existingHost: ComputeHostRecord? = nil, authToken: String,
        timeout: TimeInterval = 30
    ) throws -> ComputeHostBootstrapResult {
        let prepared = try ComputeHostDraftBuilder.prepare(draft: draft, resolvedSSH: resolvedSSH, existing: existingHost, authToken: authToken)
        let token = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ComputeHostBootstrapError.missingAuthToken }

        let artifact = try prepareManagedArtifact(host: prepared.host, timeout: timeout, selectsAvailablePort: true)
        let outcome = try runRemoteStartScript(
            host: prepared.host, authToken: token, artifact: artifact, selectsAvailablePort: true, cleanExistingProfile: false,
            timeout: max(timeout, Self.managedArtifactInstallTimeout))
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

    static func sshCommand(host: ComputeHostRecord) -> [String] {
        var command = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=yes"]
        if let port = host.sshPort { command.append(contentsOf: ["-p", String(port)]) }
        command.append(sshDestination(host: host))
        command.append("sh -c 'IFS= read -r spacesd_auth_token; export spacesd_auth_token; exec bash -s'")
        return command
    }

    static func sshScriptCommand(host: ComputeHostRecord) -> [String] {
        var command = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=yes"]
        if let port = host.sshPort { command.append(contentsOf: ["-p", String(port)]) }
        command.append(sshDestination(host: host))
        command.append("bash -s")
        return command
    }

    public static func sshOpenCommand(host: ComputeHostRecord) -> String {
        var parts = ["ssh"]
        if let port = host.sshPort { parts.append(contentsOf: ["-p", String(port)]) }
        parts.append(sshDestination(host: host))
        return parts.map(shellArgument).joined(separator: " ")
    }

    static func remoteStartInput(
        host: ComputeHostRecord, authToken: String, artifact: RemoteSpacesArtifact, selectsAvailablePort: Bool = false,
        cleanExistingProfile: Bool = false
    ) -> String {
        "\(authToken)\n\(remoteStartScript(host: host, artifact: artifact, selectsAvailablePort: selectsAvailablePort, cleanExistingProfile: cleanExistingProfile))"
    }

    private func prepareManagedArtifact(host: ComputeHostRecord, timeout: TimeInterval, selectsAvailablePort: Bool) throws -> RemoteSpacesArtifact {
        let releasePageURL =
            (try? RemoteSpacesArtifactReleaseSource.githubReleasePageURL().absoluteString) ?? "https://github.com/yogesh-dhande/spaces/releases"
        let probe: RemoteSpacesPlatformProbe
        do {
            let output = try runCommand(Self.sshScriptCommand(host: host), Self.remoteProbeScript(), timeout)
            probe = RemoteSpacesPlatformProbe.parse(output)
        } catch {
            throw setupError(
                host: host, failedCheck: .sshAccess, command: Self.sshOpenCommand(host: host),
                detail: "Strict known-host SSH to \(Self.sshDestination(host: host)) failed. \(Self.errorDescription(error))",
                fixHint: "Confirm the host is in known_hosts and that \(Self.sshOpenCommand(host: host)) works without prompts.")
        }

        do { _ = try RemoteSpacesArtifactSelector.artifactID(for: probe) } catch {
            throw setupError(
                host: host, failedCheck: .supportedPlatform, command: "uname -s; uname -m; sw_vers or /etc/os-release",
                detail: Self.errorDescription(error), fixHint: "Use macOS 14+ or Ubuntu 24.04 on x86_64 or arm64.")
        }

        let manifest: RemoteSpacesArtifactManifest
        do { manifest = try artifactManifestProvider() } catch {
            throw setupError(
                host: host, failedCheck: .artifactManifest, command: "Open \(releasePageURL)",
                detail:
                    "Spaces could not verify the managed remote artifacts for this build. Open \(releasePageURL). \(Self.errorDescription(error))",
                fixHint: "Open \(releasePageURL) and confirm this build's managed remote artifacts are published and reachable, then reinstall.")
        }

        let artifact: RemoteSpacesArtifact
        do { artifact = try RemoteSpacesArtifactSelector.select(manifest: manifest, for: probe) } catch {
            throw setupError(
                host: host, failedCheck: .supportedPlatform, command: "select exact artifact for \(probe.operatingSystem) \(probe.architecture)",
                detail: Self.errorDescription(error),
                fixHint: "Install a supported remote OS/architecture or publish the matching remote artifact to the current release.")
        }

        do {
            _ = try runCommand(
                Self.sshScriptCommand(host: host), Self.remotePreflightScript(host: host, selectsAvailablePort: selectsAvailablePort), timeout)
        } catch {
            let parsed = Self.parseSetupFailure(error)
            throw setupError(host: host, failedCheck: parsed.checkID, command: parsed.command, detail: parsed.detail, fixHint: parsed.fixHint)
        }

        return artifact
    }

    private func runRemoteStartScript(
        host: ComputeHostRecord, authToken: String, artifact: RemoteSpacesArtifact, selectsAvailablePort: Bool, cleanExistingProfile: Bool,
        timeout: TimeInterval
    ) throws -> ComputeHostBootstrapOutcome {
        do {
            let output = try runCommand(
                Self.sshCommand(host: host),
                Self.remoteStartInput(
                    host: host, authToken: authToken, artifact: artifact, selectsAvailablePort: selectsAvailablePort,
                    cleanExistingProfile: cleanExistingProfile), timeout)
            return try Self.parseBootstrapOutput(output)
        } catch let error as ComputeHostBootstrapError {
            switch error {
            case .invalidBootstrapOutput: throw error
            default:
                let parsed = Self.parseSetupFailure(error)
                throw setupError(host: host, failedCheck: parsed.checkID, command: parsed.command, detail: parsed.detail, fixHint: parsed.fixHint)
            }
        } catch {
            let parsed = Self.parseSetupFailure(error)
            throw setupError(host: host, failedCheck: parsed.checkID, command: parsed.command, detail: parsed.detail, fixHint: parsed.fixHint)
        }
    }

    private func setupError(host: ComputeHostRecord, failedCheck: ComputeHostSetupCheckID, command: String?, detail: String, fixHint: String?)
        -> ComputeHostSetupError
    {
        let checklist = ComputeHostSetupChecklistBuilder.failure(
            host: host, failedCheck: failedCheck, command: command, detail: detail, fixHint: fixHint)
        return ComputeHostSetupError(checklist: checklist, underlyingDescription: detail)
    }

    static func remoteProbeScript() -> String {
        """
        set -eu
        PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
        printf 'os=%s\\n' "$(uname -s)"
        printf 'arch=%s\\n' "$(uname -m)"
        if [ "$(uname -s)" = "Darwin" ]; then
          printf 'macos_version=%s\\n' "$(sw_vers -productVersion 2>/dev/null || true)"
        elif [ "$(uname -s)" = "Linux" ]; then
          if [ -r /etc/os-release ]; then
            . /etc/os-release
            printf 'linux_id=%s\\n' "${ID:-}"
            printf 'linux_version_id=%s\\n' "${VERSION_ID:-}"
          fi
        fi
        """
    }

    static func remotePreflightScript(host: ComputeHostRecord, selectsAvailablePort: Bool = false) -> String {
        let hostID = safePathComponent(host.id)
        let workspaceRoot = shellSingleQuoted(host.workspaceRoot)
        return """
            set -eu
            PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
            fail() {
              echo "SPACES_SETUP_FAILED_CHECK=$1" >&2
              echo "SPACES_SETUP_FAILED_COMMAND=$2" >&2
              echo "SPACES_SETUP_FAILED_FIX=$3" >&2
              echo "$4" >&2
              exit 1
            }
            require_tool() {
              command -v "$1" >/dev/null 2>&1 || fail requiredTools "command -v $1" "Install $1 on the remote host." "$1 is required on the remote host."
            }
            profile_root="${HOME}/.spaces/compute-hosts/\(hostID)"
            daemon_root="${profile_root}/daemon"
            requested_port=\(host.daemonEndpoint.port)
            workspace_root_input=\(workspaceRoot)
            case "${workspace_root_input}" in
              '$HOME'|'$HOME/'*) workspace_root="${HOME}${workspace_root_input#\\$HOME}" ;;
              '~'|'~/'*) workspace_root="${HOME}${workspace_root_input#\\~}" ;;
              /*) workspace_root="${workspace_root_input}" ;;
              *) workspace_root="${HOME}/${workspace_root_input}" ;;
            esac
            for tool in curl tar gzip lsof python3 git; do
              require_tool "${tool}"
            done
            if command -v sha256sum >/dev/null 2>&1; then
              :
            elif command -v shasum >/dev/null 2>&1; then
              :
            else
              fail requiredTools "command -v sha256sum || command -v shasum" "Install coreutils or Perl shasum on the remote host." "A SHA-256 checksum tool is required."
            fi
            mkdir -p "${profile_root}" "${daemon_root}/releases" "${profile_root}/uploads" "${profile_root}/runtime" "${profile_root}/bin" "${workspace_root}" \
              || fail writableInstallRoot "mkdir -p ${profile_root}" "Make ~/.spaces writable for the SSH user." "Could not create the Spaces install root."
            [ -w "${profile_root}" ] || fail writableInstallRoot "test -w ${profile_root}" "Make ~/.spaces writable for the SSH user." "The Spaces install root is not writable."
            if [ "\(selectsAvailablePort ? "1" : "0")" = "1" ]; then
              selected_port=""
              port_candidate="${requested_port}"
              last_port=$((requested_port + 9))
              while [ "${port_candidate}" -le "${last_port}" ]; do
                if ! lsof -nPiTCP:${port_candidate} -sTCP:LISTEN >/dev/null 2>&1; then
                  selected_port="${port_candidate}"
                  break
                fi
                port_candidate=$((port_candidate + 1))
              done
              [ -n "${selected_port}" ] || fail portAvailability "lsof -nPiTCP:${requested_port}-${last_port}" "Free a port in ${requested_port}-${last_port} or remove the conflicting listener." "No available spacesd port found in ${requested_port}-${last_port}."
            fi
            printf 'preflight=ok\\n'
            """
    }

    static func remoteStartScript(
        host: ComputeHostRecord, artifact: RemoteSpacesArtifact, selectsAvailablePort: Bool = false, cleanExistingProfile: Bool = false
    ) -> String {
        let hostID = safePathComponent(host.id)
        let workspaceRoot = shellSingleQuoted(host.workspaceRoot)
        let port = host.daemonEndpoint.port
        let artifactID = shellSingleQuoted(artifact.id)
        let artifactVersion = shellSingleQuoted(artifact.version)
        let archiveURL = shellSingleQuoted(artifact.url)
        let archiveSHA256 = shellSingleQuoted(artifact.sha256)
        let archiveName = shellSingleQuoted(artifact.archiveName)
        let cleanProfileScript = cleanExistingProfile ? #"rm -rf "${profile_root}""# : ""
        let portSelectionScript: String
        if selectsAvailablePort {
            portSelectionScript = """
                selected_port=""
                port_candidate="${requested_port}"
                last_port=$((requested_port + 9))
                while [ "${port_candidate}" -le "${last_port}" ]; do
                  if ! lsof -nPiTCP:${port_candidate} -sTCP:LISTEN >/dev/null 2>&1; then
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
        let requiredPortAvailabilityScript = """
            if lsof -nPiTCP:${selected_port} -sTCP:LISTEN >/dev/null 2>&1; then
              fail portAvailability "lsof -nPiTCP:${selected_port} -sTCP:LISTEN" "Stop the listener on port ${selected_port}, then retry setup." "Port ${selected_port} is already in use."
            fi
            """

        return """
            if [ -z "${spacesd_auth_token}" ]; then
              echo "spacesd auth token is required." >&2
              exit 1
            fi
            set -eu
            PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
            fail() {
              echo "SPACES_SETUP_FAILED_CHECK=$1" >&2
              echo "SPACES_SETUP_FAILED_COMMAND=$2" >&2
              echo "SPACES_SETUP_FAILED_FIX=$3" >&2
              echo "$4" >&2
              exit 1
            }
            checksum_file() {
              if command -v sha256sum >/dev/null 2>&1; then
                sha256sum "$1" | awk '{print $1}'
              else
                shasum -a 256 "$1" | awk '{print $1}'
              fi
            }
            check_sha256sums() {
              if command -v sha256sum >/dev/null 2>&1; then
                sha256sum -c SHA256SUMS
              else
                shasum -a 256 -c SHA256SUMS
              fi
            }
            profile_root="${HOME}/.spaces/compute-hosts/\(hostID)"
            daemon_root="${profile_root}/daemon"
            runtime_root="${profile_root}/runtime"
            pid_path="${runtime_root}/spacesd.pid"
            db_path="${profile_root}/spaces.db"
            requested_port=\(port)
            artifact_id=\(artifactID)
            artifact_version=\(artifactVersion)
            archive_url=\(archiveURL)
            archive_sha256=\(archiveSHA256)
            archive_name=\(archiveName)
            workspace_root_input=\(workspaceRoot)
            case "${workspace_root_input}" in
              '$HOME'|'$HOME/'*) workspace_root="${HOME}${workspace_root_input#\\$HOME}" ;;
              '~'|'~/'*) workspace_root="${HOME}${workspace_root_input#\\~}" ;;
              /*) workspace_root="${workspace_root_input}" ;;
              *) workspace_root="${HOME}/${workspace_root_input}" ;;
            esac
            \(cleanProfileScript)
            mkdir -p "${profile_root}" "${daemon_root}/releases" "${profile_root}/uploads" "${runtime_root}" "${workspace_root}" "${profile_root}/bin"
            release_root="${daemon_root}/releases/${artifact_version}"
            if [ ! -x "${release_root}/bin/spacesd" ]; then
              tmp_dir="$(mktemp -d "${profile_root}/uploads/spacesd.XXXXXX")"
              archive_path="${tmp_dir}/${archive_name}"
              curl -fL "${archive_url}" -o "${archive_path}" \
                || fail archiveChecksum "curl -fL ${archive_url}" "Confirm this Mac can access the GitHub Release asset from the remote host." "Could not download the selected spacesd archive."
              actual_sha="$(checksum_file "${archive_path}")"
              [ "${actual_sha}" = "${archive_sha256}" ] \
                || fail archiveChecksum "sha256 ${archive_path}" "Retry setup; if it still fails, the release asset does not match the signed manifest." "Archive SHA-256 mismatch. Expected ${archive_sha256}, got ${actual_sha}."
              extract_root="${tmp_dir}/extract"
              mkdir -p "${extract_root}"
              tar -xzf "${archive_path}" -C "${extract_root}" \
                || fail internalChecksums "tar -xzf ${archive_path}" "Retry setup or republish the remote artifact archive." "Could not extract the selected spacesd archive."
              [ -d "${extract_root}/${artifact_id}" ] \
                || fail internalChecksums "test -d ${artifact_id}" "Republish the remote artifact with the expected root directory." "Archive root ${artifact_id} was not found."
              (cd "${extract_root}/${artifact_id}" && check_sha256sums >/dev/null) \
                || fail internalChecksums "sha256sum -c SHA256SUMS" "Retry setup or republish the remote artifact archive." "Archive internal SHA256SUMS validation failed."
              rm -rf "${release_root}.tmp"
              mv "${extract_root}/${artifact_id}" "${release_root}.tmp"
              rm -rf "${release_root}"
              mv "${release_root}.tmp" "${release_root}"
              rm -rf "${tmp_dir}"
            fi
            ln -sfn "releases/${artifact_version}" "${daemon_root}/current"
            ln -sfn "${daemon_root}/current/bin" "${daemon_root}/bin"
            ln -sfn "${daemon_root}/bin/spaces" "${profile_root}/bin/spaces"
            spacesd_path="${daemon_root}/bin/spacesd"
            [ -x "${spacesd_path}" ] || fail daemonLaunch "test -x ${spacesd_path}" "Retry setup or republish the remote artifact archive." "Managed spacesd is not executable after install."
            PATH="${profile_root}/bin:${daemon_root}/bin:$PATH"
            fingerprint="$(SPACES_DB_PATH="${db_path}" SPACES_RUNTIME_DIR="${runtime_root}" SPACESD_PRINT_CERTIFICATE_FINGERPRINT=1 "${spacesd_path}")"
            if [ -z "${fingerprint}" ]; then
              fail certificateFingerprint "SPACESD_PRINT_CERTIFICATE_FINGERPRINT=1 ${spacesd_path}" "Check the managed spacesd log and retry setup." "spacesd did not print a certificate fingerprint."
            fi
            \(portSelectionScript)
            \(requiredPortAvailabilityScript)
            log_path="${profile_root}/spacesd-${selected_port}.log"
            nohup env PATH="${PATH}" SPACES_DB_PATH="${db_path}" SPACES_RUNTIME_DIR="${runtime_root}" SPACESD_LISTEN_PORT="${selected_port}" SPACESD_AUTH_TOKEN="${spacesd_auth_token}" SPACESD_ARTIFACT_VERSION="${artifact_version}" "${spacesd_path}" >>"${log_path}" 2>&1 &
            daemon_pid="$!"
            printf '%s\\n' "${daemon_pid}" > "${pid_path}"
            ready_attempt=0
            listener_ready=0
            while [ "${ready_attempt}" -lt 100 ]; do
              if lsof -nPiTCP:${selected_port} -sTCP:LISTEN >/dev/null 2>&1; then
                listener_ready=1
                break
              fi
              ready_attempt=$((ready_attempt + 1))
              sleep 0.2
            done
            if [ "${listener_ready}" != "1" ]; then
              if [ -f "${log_path}" ]; then tail -n 40 "${log_path}" >&2 || true; fi
              fail daemonLaunch "SPACESD_LISTEN_PORT=${selected_port} ${spacesd_path}" "Inspect ${log_path} on \(host.sshHost) and retry setup." "spacesd did not start listening on port ${selected_port}."
            fi
            printf 'fingerprint=%s\\n' "${fingerprint}"
            printf 'workspace_root=%s\\n' "${workspace_root}"
            printf 'port=%s\\n' "${selected_port}"
            printf 'pid=%s\\n' "${daemon_pid}"
            printf 'log=%s\\n' "${log_path}"
            printf 'artifact_id=%s\\n' "${artifact_id}"
            printf 'artifact_version=%s\\n' "${artifact_version}"
            """
    }

    static func remoteUninstallScript(host: ComputeHostRecord) -> String {
        let hostID = safePathComponent(host.id)
        let port = host.daemonEndpoint.port
        return """
            set -eu
            PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
            fail() {
              echo "SPACES_SETUP_FAILED_CHECK=$1" >&2
              echo "SPACES_SETUP_FAILED_COMMAND=$2" >&2
              echo "SPACES_SETUP_FAILED_FIX=$3" >&2
              echo "$4" >&2
              exit 1
            }
            profile_root="${HOME}/.spaces/compute-hosts/\(hostID)"
            daemon_root="${profile_root}/daemon"
            runtime_root="${profile_root}/runtime"
            pid_path="${runtime_root}/spacesd.pid"
            daemon_port=\(port)
            command -v lsof >/dev/null 2>&1 || fail requiredTools "command -v lsof" "Install lsof on the remote host." "lsof is required to confirm spacesd has stopped."
            if [ -f "${pid_path}" ]; then
              old_pid="$(cat "${pid_path}" 2>/dev/null || true)"
              if [ -n "${old_pid}" ] && kill -0 "${old_pid}" >/dev/null 2>&1; then
                old_command="$(ps -p "${old_pid}" -o command= 2>/dev/null || true)"
                case "${old_command}" in
                  *"${profile_root}/daemon/"*) fail daemonLaunch "spacesd shutdownIfIdle" "Wait for the managed spacesd process ${old_pid} to exit, then retry uninstall." "Managed spacesd is still running." ;;
                  *) fail daemonLaunch "ps -p ${old_pid} -o command=" "Stop the non-managed process recorded at ${pid_path}, then retry uninstall." "Recorded pid ${old_pid} is not the managed spacesd process." ;;
                esac
              fi
            fi
            if lsof -nPiTCP:${daemon_port} -sTCP:LISTEN >/dev/null 2>&1; then
              fail daemonLaunch "lsof -nPiTCP:${daemon_port} -sTCP:LISTEN" "Wait for spacesd on port ${daemon_port} to exit, then retry uninstall." "spacesd is still listening on port ${daemon_port}."
            fi
            rm -rf "${daemon_root}" "${profile_root}/uploads"
            rm -f "${profile_root}/bin/spaces" "${pid_path}"
            printf 'uninstalled=1\\n'
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

    private static func shellArgument(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-./:@")
        if value.unicodeScalars.allSatisfy({ allowed.contains($0) }) { return value }
        return shellSingleQuoted(value)
    }

    private static func parseSetupFailure(_ error: Error) -> (checkID: ComputeHostSetupCheckID, command: String?, fixHint: String?, detail: String) {
        let description = errorDescription(error)
        var values: [String: String] = [:]
        var details: [String] = []
        for rawLine in description.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("SPACES_SETUP_FAILED_") {
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
            } else if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                details.append(line)
            }
        }
        let checkID = values["SPACES_SETUP_FAILED_CHECK"].flatMap(ComputeHostSetupCheckID.init(rawValue:)) ?? .daemonLaunch
        return (
            checkID, values["SPACES_SETUP_FAILED_COMMAND"], values["SPACES_SETUP_FAILED_FIX"],
            details.isEmpty ? description : details.joined(separator: "\n")
        )
    }

    private static func errorDescription(_ error: Error) -> String { (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }

    private static func defaultArtifactManifestProvider() throws -> RemoteSpacesArtifactManifest {
        try RemoteSpacesArtifactReleaseSource.githubRelease().loadManifest()
    }

    private static func defaultRunCommand(_ command: [String], standardInput: String, timeout: TimeInterval) throws -> String {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        if let data = standardInput.data(using: .utf8) { input.fileHandleForWriting.write(data) }
        try? input.fileHandleForWriting.close()

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
