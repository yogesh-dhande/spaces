import CryptoKit
import XCTest
import spacesterminalcore
import systembridge

@testable import workspacecore

final class WorkspaceSetupThread: Thread {
    private let orchestrator: WorkspaceOrchestrator
    private let workspaceID: String

    init(orchestrator: WorkspaceOrchestrator, workspaceID: String) {
        self.orchestrator = orchestrator
        self.workspaceID = workspaceID
    }

    override func main() { try? orchestrator.runWorkspaceSetup(workspaceID: workspaceID) }
}

final class TerminalOpenCapture: @unchecked Sendable {
    var sessionIDs: [String] = []
    var modes: [TerminalAttachmentMode] = []
}

final class TerminalLaunchConfigurationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var configurations: [TerminalSessionLaunchConfiguration] = []

    func append(_ configuration: TerminalSessionLaunchConfiguration) {
        lock.lock()
        configurations.append(configuration)
        lock.unlock()
    }

    func snapshot() -> [TerminalSessionLaunchConfiguration] {
        lock.lock()
        defer { lock.unlock() }
        return configurations
    }
}

final class TerminalCloseCapture: @unchecked Sendable { var sessionIDs: [String] = [] }

final class TerminalTerminateCapture: @unchecked Sendable { var sessionIDs: [String] = [] }

final class TerminalLaunchAttemptCapture: @unchecked Sendable { var count = 0 }

final class RemoteStateCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let sessionID: String
    private let workspaceID: String
    private let workingDirectory: String
    private var recordedRequests: [TerminalServiceRequest] = []

    init(sessionID: String, workspaceID: String, workingDirectory: String) {
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.workingDirectory = workingDirectory
    }

    func client(target _: SpacesDaemonConnectionTarget, request: TerminalServiceRequest) throws -> TerminalServiceResponse {
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()

        guard case .state(let payload) = request.command, payload.sessionID == sessionID else {
            return TerminalServiceResponse(ok: true, message: "ok")
        }
        let timestamp = "2026-06-11T00:00:00Z"
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 42, childPID: 4242, state: .running, updatedAt: timestamp, title: "shell-1",
            workingDirectory: workingDirectory)
        let client = TerminalClient(
            id: "owner-client", kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Owner Mac"),
            connectedAt: timestamp)
        let attachment = TerminalAttachment(sessionID: sessionID, clientID: client.id, mode: .owner, attachedAt: timestamp)
        return TerminalServiceResponse(
            ok: true, message: "state",
            sessionState: GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.stateChange, emittedAt: timestamp, sessionStateRevision: 1,
                sessionStateFlags: nil, screenStateRevision: nil, runtimeState: runtimeState,
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [client], attachments: [attachment]), title: "shell-1",
                workingDirectory: workingDirectory, outputByteCount: 0))
    }

    func requests() -> [TerminalServiceRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }
}

func managedProjectStorageDirname(namespace: String, source: String, preferredName: String) -> String {
    let digest = SHA256.hash(data: Data("\(namespace)\u{0}\(source)".utf8)).map { String(format: "%02x", $0) }.joined()
    let cleaned = preferredName.map { char -> String in
        if char.isLetter || char.isNumber { return String(char) }
        if char == "-" || char == "_" { return String(char) }
        return "-"
    }.joined()
    let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    let sanitizedName = trimmed.isEmpty ? "project" : trimmed
    let hashSuffix = String(digest.prefix(16))
    let maxNameLength = max(1, 255 - hashSuffix.count - 1)
    let truncatedName = String(sanitizedName.prefix(maxNameLength))
    return "\(truncatedName)-\(hashSuffix)"
}

final class OrchestratorTests: XCTestCase {

    final class TestClock {
        private var current: Date

        init(now: Date) { current = now }

        func now() -> Date { current }

        func advance(seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
    }

    func makeOrchestratorWithWorkspace(
        currentDate: @escaping () -> Date = Date.init
    ) throws -> (WorkspaceOrchestrator, SQLiteStore, ProjectRecord, WorkspaceRecord, URL) {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let dbPath = root.appendingPathComponent("spaces-test.db").path
        let store = try SQLiteStore(path: dbPath)
        let orchestrator = WorkspaceOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { sessionID, _ in
                try! withSpacesProfileEnvironment(dbPath: dbPath) {
                    let paths = try TerminalSessionPaths.forSession(id: sessionID)
                    try paths.ensureDirectories()
                    FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                    try TerminalSessionPersistence.writeRuntimeState(
                        .init(
                            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 4321, state: .running,
                            updatedAt: "2026-05-15T18:00:00Z"), paths: paths)
                    try "test output\n".write(toFile: paths.outputPath, atomically: true, encoding: .utf8)
                }
            },
            builtInTerminalSessionLauncher: { configuration in
                try withSpacesProfileEnvironment(dbPath: dbPath) {
                    let paths = try TerminalSessionPaths.forSession(id: configuration.sessionID)
                    try paths.ensureDirectories()
                    try TerminalSessionPersistence.writeLaunchConfiguration(configuration, paths: paths)
                    FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
                    FileManager.default.createFile(atPath: paths.outputPath, contents: nil)
                    let runtimeState =
                        (try? TerminalSessionPersistence.readRuntimeState(paths: paths))
                        ?? TerminalSessionRuntimeState(
                            sessionID: configuration.sessionID, backend: configuration.backend,
                            servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: 4321, state: .running,
                            updatedAt: "2026-05-15T18:00:00Z", title: configuration.title, workingDirectory: configuration.workingDirectory)
                    try TerminalSessionPersistence.writeRuntimeState(runtimeState, paths: paths)
                    return TerminalServiceSessionSummary(
                        id: configuration.sessionID, title: runtimeState.title ?? configuration.title,
                        workingDirectory: runtimeState.workingDirectory ?? configuration.workingDirectory, backend: configuration.backend,
                        lifetimePolicy: configuration.lifetimePolicy, state: runtimeState.state, servicePID: runtimeState.servicePID,
                        childPID: runtimeState.childPID, controlSocketPath: paths.controlSocketPath, outputPath: paths.outputPath)
                }
            }, currentDate: currentDate)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        return (orchestrator, store, project, workspace, root)
    }

    func spacesYAMLFixture(stopScript: String) -> String {
        """
        version: 1
        setup_script: npm install
        stop_script: \(stopScript)
        ports:
          - name: API_PORT
        processes:
          - name: api
            command: npm run api
            on_exit: none
        browser_sessions:
          - name: app
            url: http://localhost:3000
        agent_launchers:
          - name: Codex
            command: codex
        """
    }

    func writeTerminalSessionFixture(
        sessionID: String, workspace: WorkspaceRecord, kind: TerminalSessionKind, runtimeState: TerminalSessionRuntimeState
    ) throws {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, title: runtimeState.title ?? sessionID,
                workingDirectory: runtimeState.workingDirectory ?? workspace.dir, shell: "/bin/zsh", command: nil, createdAt: "2026-06-06T00:00:00Z",
                workspaceID: workspace.id, kind: kind), paths: paths)
        try TerminalSessionPersistence.writeRuntimeState(runtimeState, paths: paths)
    }

    func withEnv(name: String, value: String, run: () throws -> Void) throws {
        if name == SpacesProfile.databasePathEnvironmentVariable {
            try withSpacesProfileEnvironment(dbPath: value, run: run)
            return
        }
        let original = ProcessInfo.processInfo.environment[name]
        setenv(name, value, 1)
        defer { if let original { setenv(name, original, 1) } else { unsetenv(name) } }
        try run()
    }

    static let orchestratorOsaScriptMock = """
        #!/bin/bash
        # Mock `osascript` bridge for Chrome paths used by orchestrator tests.
        # Coverage intent:
        # - Chrome availability/session stubs
        # Residual risk: no validation of true AppleScript syntax/runtime against installed applications.
        script="${*: -1}"
        chrome_active_url_file="${MOCK_CHROME_ACTIVE_URL_FILE:-}"
        if [[ -z "$chrome_active_url_file" && -n "${MOCK_CHROME_FOCUS_LOG_FILE:-}" ]]; then
          chrome_active_url_file="${MOCK_CHROME_FOCUS_LOG_FILE}.active"
        fi
        extract_window_id() {
          local source="$1"
          local extracted
          extracted="$(printf '%s\n' "$source" | awk -F'set requestedWindowID to \"' 'NF>1 { sub(/\".*/, "", $2); print $2; exit }')"
          if [[ -n "$extracted" ]]; then
            echo "$extracted"
            return
          fi
          printf '%s\n' "$source" | grep -Eo 'if id of w is [0-9]+ then' | awk '{print $6}' | head -n1
        }

        sleep_ms() {
          local value="$1"
          if [[ -z "$value" || "$value" == "0" ]]; then
            return
          fi
          local cap="${MOCK_TEST_DELAY_CAP_MS:-25}"
          if [[ "$value" =~ ^[0-9]+$ && "$cap" =~ ^[0-9]+$ && "$value" -gt "$cap" ]]; then
            value="$cap"
          fi
          perl -e "select(undef, undef, undef, $value / 1000);"
        }

        if [[ "$script" == *'tell application "Google Chrome" to version'* ]]; then
          echo "122"
          exit 0
        fi

        if [[ "$script" == *'set active tab index of front window to 1'* ]]; then
          if [[ -n "${MOCK_CHROME_TAB_INDEX_LOG_FILE:-}" ]]; then
            echo "front\t1" >> "$MOCK_CHROME_TAB_INDEX_LOG_FILE"
          fi
          echo "1"
          exit 0
        fi

        if [[ "$script" == *'set output to ""'* ]]; then
          sleep_ms "${MOCK_CHROME_SCAN_DELAY_MS:-0}"
          if [[ -n "${MOCK_CHROME_SCAN_LOG_FILE:-}" ]]; then
            echo "scan" >> "$MOCK_CHROME_SCAN_LOG_FILE"
          fi
          if [[ "${MOCK_CHROME_SCAN_FAIL:-}" == "1" ]]; then
            echo "scan failed" >&2
            exit 1
          fi
          if [[ -n "${MOCK_CHROME_WINDOW_MATCHES:-}" ]]; then
            printf "%b" "$MOCK_CHROME_WINDOW_MATCHES"
          else
            echo ""
          fi
          exit 0
        fi

        if [[ "$script" == *'set u to URL of tab requestedTabIndex of w'* ]]; then
          requested_tab_index="$(printf '%s\n' "$script" | grep -Eo 'set requestedTabIndex to [0-9]+' | awk '{print $4}' | head -n1)"
          focused_window_id="$(extract_window_id "$script")"
          if [[ -n "${MOCK_CHROME_TAB_INDEX_URL:-}" ]]; then
            echo "$MOCK_CHROME_TAB_INDEX_URL"
            exit 0
          fi
          indexed_url=""
          if [[ -n "${MOCK_CHROME_WINDOW_MATCHES:-}" && -n "$focused_window_id" && -n "$requested_tab_index" ]]; then
            indexed_url="$(printf "%b" "$MOCK_CHROME_WINDOW_MATCHES" | awk -F $'\t' -v wid="$focused_window_id" -v target="$requested_tab_index" '($1 == wid) { count += 1; if (count == target) { print $NF; exit } }')"
          fi
          echo "$indexed_url"
          exit 0
        fi

        if [[ "$script" == *'set targetTab to tab requestedTabIndex of w'* ]]; then
          sleep_ms "${MOCK_CHROME_EXTRACT_DELAY_MS:-0}"
          requested_tab_index="$(printf '%s\n' "$script" | grep -Eo 'set requestedTabIndex to [0-9]+' | awk '{print $4}' | head -n1)"
          focused_window_id="$(extract_window_id "$script")"
          if [[ -n "${MOCK_CHROME_EXTRACT_LOG_FILE:-}" ]]; then
            echo "${focused_window_id:-*}\t${requested_tab_index:-0}" >> "$MOCK_CHROME_EXTRACT_LOG_FILE"
          fi
          echo "${MOCK_CHROME_EXTRACT_WINDOW_ID:-888}"
          exit 0
        fi

        if [[ "$script" == *'set requestedTabIndex to'* ]]; then
          sleep_ms "${MOCK_CHROME_TAB_INDEX_DELAY_MS:-0}"
          requested_tab_index="$(printf '%s\n' "$script" | grep -Eo 'set requestedTabIndex to [0-9]+' | awk '{print $4}' | head -n1)"
          focused_window_id="$(extract_window_id "$script")"
          if [[ -n "${MOCK_CHROME_TAB_INDEX_LOG_FILE:-}" ]]; then
            echo "${focused_window_id:-*}\t${requested_tab_index:-0}" >> "$MOCK_CHROME_TAB_INDEX_LOG_FILE"
          fi
          focused_url=""
          if [[ -n "${MOCK_CHROME_WINDOW_MATCHES:-}" && -n "$focused_window_id" && -n "$requested_tab_index" ]]; then
            focused_url="$(printf "%b" "$MOCK_CHROME_WINDOW_MATCHES" | awk -F $'\t' -v wid="$focused_window_id" -v target="$requested_tab_index" '($1 == wid) { count += 1; if (count == target) { print $NF; exit } }')"
          fi
          focused_active_url="$focused_url"
          if [[ -n "${MOCK_CHROME_TAB_INDEX_ACTIVE_URL:-}" ]]; then
            focused_active_url="$MOCK_CHROME_TAB_INDEX_ACTIVE_URL"
          fi
          if [[ -n "$focused_active_url" ]]; then
            if [[ -n "${MOCK_CHROME_FOCUS_LOG_FILE:-}" ]]; then
              echo "$focused_active_url" >> "$MOCK_CHROME_FOCUS_LOG_FILE"
            fi
            if [[ -n "$chrome_active_url_file" ]]; then
              echo "$focused_active_url" > "$chrome_active_url_file"
            fi
          fi
          echo "${MOCK_CHROME_TAB_INDEX_FOCUS_RESULT:-1}"
          exit 0
        fi

        if [[ "$script" == *'set tabCount to count of tabs of w'* && "$script" == *'close tab i of w'* ]]; then
          if [[ "${MOCK_CHROME_CLOSE_REQUIRE_PREFIX:-}" == "1" && "$script" != *'u starts with \"'* ]]; then
            echo "0"
            exit 0
          fi
          close_url="$(printf '%s\n' "$script" | awk -F'u is \"' 'NF>1 { sub(/\".*/, "", $2); print $2; exit }')"
          if [[ -z "$close_url" ]]; then
            close_url="$(printf '%s\n' "$script" | awk -F'u starts with \"' 'NF>1 { sub(/\".*/, "", $2); print $2; exit }')"
          fi
          close_window_id="$(extract_window_id "$script")"
          if [[ -n "${MOCK_CHROME_CLOSE_LOG_FILE:-}" ]]; then
            echo "${close_window_id:-*}\t${close_url}" >> "$MOCK_CHROME_CLOSE_LOG_FILE"
          fi
          echo "${MOCK_CHROME_CLOSE_RESULT:-1}"
          exit 0
        fi

        if [[ "$script" == *'set tabCount to count of tabs of w'* ]]; then
          focused_url="$(printf '%s\n' "$script" | awk -F'starts with \"' 'NF>1 { sub(/\".*/, "", $2); print $2; exit }')"
          if [[ -z "$focused_url" ]]; then
            focused_url="$(printf '%s\n' "$script" | awk -F'u is \"' 'NF>1 { sub(/\".*/, "", $2); print $2; exit }')"
          fi
          focused_window_id="$(extract_window_id "$script")"
          if [[ -n "$focused_window_id" && -n "${MOCK_CHROME_FOCUS_WINDOW_LOG_FILE:-}" ]]; then
            echo "$focused_window_id" >> "$MOCK_CHROME_FOCUS_WINDOW_LOG_FILE"
          fi
          if [[ -n "$focused_url" ]]; then
            if [[ -n "${MOCK_CHROME_FOCUS_LOG_FILE:-}" ]]; then
              echo "$focused_url" >> "$MOCK_CHROME_FOCUS_LOG_FILE"
            fi
            if [[ -n "$chrome_active_url_file" ]]; then
              echo "$focused_url" > "$chrome_active_url_file"
            fi
          fi
          echo "${MOCK_CHROME_FOCUS_RESULT:-1}"
          exit 0
        fi

        if [[ "$script" == *'URL of active tab of front window'* ]]; then
          sleep_ms "${MOCK_CHROME_ACTIVE_URL_DELAY_MS:-0}"
          if [[ -n "$chrome_active_url_file" && -f "$chrome_active_url_file" ]]; then
            cat "$chrome_active_url_file"
          else
            echo "${MOCK_CHROME_ACTIVE_URL:-}"
          fi
          exit 0
        fi

        if [[ "$script" == *'set URL of active tab of newWindow'* ]]; then
          if [[ -n "${MOCK_CHROME_OPEN_LOG_FILE:-}" ]]; then
            echo "$script" >> "$MOCK_CHROME_OPEN_LOG_FILE"
          fi
          echo "88"
          exit 0
        fi

        if [[ "$script" == *'make new tab at end of tabs of w with properties {URL:'* ]]; then
          if [[ -n "${MOCK_CHROME_OPEN_LOG_FILE:-}" ]]; then
            echo "$script" >> "$MOCK_CHROME_OPEN_LOG_FILE"
          fi
          echo "${MOCK_CHROME_OPEN_TAB_RESULT:-1}"
          exit 0
        fi

        echo ""
        exit 0
        """

    static let killMockScript = """
        #!/bin/bash
        if [[ -n "${MOCK_KILL_LOG_FILE:-}" ]]; then
          echo "kill $*" >> "$MOCK_KILL_LOG_FILE"
        fi
        exit 0
        """

    static let openMockScript = """
        #!/bin/bash
        # Mock `open` for editor-launch assertions.
        # Residual risk: launch service resolution and app startup behavior are not exercised.
        if [[ -n "${OPEN_LOG_FILE:-}" ]]; then
          echo "$*" >> "$OPEN_LOG_FILE"
        fi
        exit 0
        """

    func parseWorktreePaths(_ porcelainOutput: String) -> Set<String> {
        Set(
            porcelainOutput.split(separator: "\n").compactMap { rawLine -> String? in
                let line = String(rawLine)
                guard line.hasPrefix("worktree ") else { return nil }
                let path = String(line.dropFirst("worktree ".count))
                return normalizeTestPath(path)
            })
    }

    func normalizeTestPath(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }

    func makeRemoteFixture() throws -> (root: URL, source: URL, remote: URL, clone: URL) {
        let root = try makeTempDirectory()
        let source = root.appendingPathComponent("source", isDirectory: true)
        try initializeGitRepository(at: source, initialBranch: "main")

        let remote = root.appendingPathComponent("remote.git", isDirectory: true)
        try runGit(["clone", "--bare", source.path, remote.path], cwd: root.path)

        let clone = root.appendingPathComponent("clone", isDirectory: true)
        try runGit(["clone", remote.path, clone.path], cwd: root.path)
        return (root, source, remote, clone)
    }

    func makeLsRemoteFailingGitClient() throws -> GitClient {
        let toolsRoot = try makeExecutableTestToolsDirectory()
        let script = toolsRoot.appendingPathComponent("git")
        let contents = """
            #!/bin/sh
            subcommand=""
            expect_value=0
            for arg in "$@"; do
              if [ "$expect_value" -eq 1 ]; then
                expect_value=0
                continue
              fi
              case "$arg" in
                -C|--git-dir|--work-tree)
                  expect_value=1
                  continue
                  ;;
                -*)
                  continue
                  ;;
                *)
                  subcommand="$arg"
                  break
                  ;;
              esac
            done
            if [ "$subcommand" = "ls-remote" ]; then
              echo "remote lookup failed" >&2
              exit 128
            fi
            exec /usr/bin/git "$@"
            """
        try contents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return GitClient(gitExecutable: script.path)
    }

    func makeExecutableTestToolsDirectory() throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = packageRoot.appendingPathComponent(".build/test-tools/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        return directory
    }
}
