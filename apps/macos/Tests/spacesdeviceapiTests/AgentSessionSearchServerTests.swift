#if canImport(Network) && canImport(Security)
    import Foundation
    import XCTest
    import spacessessionindex
    import workspacecore

    @testable import spacesdeviceapi
    @testable import spacesdevicecore
    @testable import spacesterminalcore

    /// Device API coverage for searching past coding-agent conversations and resuming one: what the device
    /// adds to each hit from its own state (the workspace a resume opens in, whether it runs or is pinned,
    /// whether its folder is gone), and a resume that focuses, launches in the mapped workspace, or refuses.
    final class AgentSessionSearchServerTests: XCTestCase {
        private let tlsRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "spaces-agent-session-search-tests-tls-\(UUID().uuidString)", isDirectory: true)
        private var root: URL!
        private var launches: SessionSearchLaunchRecorder!
        private var operations: AgentSessionSearchOperations!

        private var homeDirectory: URL { root.appendingPathComponent("home") }
        private var atlasDirectory: URL { root.appendingPathComponent("atlas") }
        private var featureDirectory: URL { root.appendingPathComponent("atlas/trees/feature") }
        private var goneProjectDirectory: URL { root.appendingPathComponent("gone") }
        private var elsewhereDirectory: URL { root.appendingPathComponent("elsewhere") }
        private var missingDirectory: URL { root.appendingPathComponent("deleted-checkout") }
        /// Where Atlas's worktrees would be created: managed storage named after the project and its id.
        private var atlasWorktreeRoot: URL {
            get throws { try SpacesProfile.current().workspacesRootDirectory.appendingPathComponent("Atlas-atlas") }
        }

        /// Binds the profile to a throwaway database, seeds a device with a home project and two ordinary
        /// projects, and indexes a few conversations from a throwaway home, so the real stores are never read.
        override func setUpWithError() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-session-search-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let keys = [SpacesProfile.databasePathEnvironmentVariable, SpacesProfile.runtimeDirectoryEnvironmentVariable]
            let originals = keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
            let root = self.root!
            addTeardownBlock {
                for (name, value) in originals { if let value { setenv(name, value, 1) } else { unsetenv(name) } }
                try? FileManager.default.removeItem(at: root)
            }
            setenv(SpacesProfile.databasePathEnvironmentVariable, root.appendingPathComponent("spaces.db").path, 1)
            unsetenv(SpacesProfile.runtimeDirectoryEnvironmentVariable)
            launches = SessionSearchLaunchRecorder()
            try seedDevice()
            try seedIndex()
        }

        override func tearDown() {
            try? FileManager.default.removeItem(at: tlsRoot)
            super.tearDown()
        }

        // MARK: - Search

        func testHitsCarryTheWorkspaceAResumeOpensIn() throws {
            let harness = try makeHarness()
            defer { harness.stop() }

            let hits = try harness.search("")

            // The deepest workspace containing the folder wins over the project's default.
            XCTAssertEqual(try hit("claude-feature", in: hits).workspace.workspaceName, "feature")
            XCTAssertEqual(try hit("claude-feature", in: hits).workspace.projectName, "Atlas")
            // A folder that no workspace contains but a project's directory does maps to that project's default workspace.
            XCTAssertEqual(try hit("claude-gone", in: hits).workspace.projectName, "Gone")
            XCTAssertEqual(try hit("claude-gone", in: hits).workspace.workspaceName, "main")
            // A folder in no project, existing or not, maps to the home workspace.
            XCTAssertEqual(try hit("claude-elsewhere", in: hits).workspace.projectName, "~")
            XCTAssertEqual(try hit(codexMissingThread, in: hits).workspace.projectName, "~")
        }

        func testAgentWithoutItsFolderIsOnlyResumableWhenItNeedsNoFolder() throws {
            let harness = try makeHarness()
            defer { harness.stop() }

            let hits = try harness.search("")

            XCTAssertEqual(try hit("claude-gone", in: hits).resumability, .folderMissing, "Claude Code resumes only from its original folder.")
            XCTAssertEqual(try hit(codexMissingThread, in: hits).resumability, .resumable, "Codex resumes in the workspace's directory instead.")
            XCTAssertEqual(try hit("claude-feature", in: hits).resumability, .resumable)
        }

        func testAPinnedConversationShowsItsNameAndResumesInThePinsWorkspace() throws {
            let harness = try makeHarness()
            defer { harness.stop() }

            let pinned = try hit("claude-pinned", in: try harness.search(""))

            XCTAssertEqual(pinned.pinnedName, "Pinned fix")
            XCTAssertEqual(pinned.workspace.workspaceName, "feature", "The pin's workspace wins over the one the folder maps to.")
        }

        func testResumingAPinnedConversationLaunchesThePinsCommand() throws {
            let harness = try makeHarness()
            defer { harness.stop() }

            let resumed = try harness.send(
                .resumeAgentSession(.init(agent: .claudeCode, sessionKey: "claude-pinned", workingDirectory: atlasDirectory.path)))

            XCTAssertTrue(resumed.ok, resumed.message)
            let launch = try XCTUnwrap(launches.configurations().last)
            XCTAssertTrue(launch.command?.contains("claude --resume claude-pinned --model opus") == true, launch.command ?? "nil")
            XCTAssertEqual(launch.workspaceID, "feature-workspace")
            XCTAssertEqual(resumed.workspaceID, "feature-workspace")
        }

        func testAgentFilterQueryAndAvailableAgents() throws {
            let harness = try makeHarness()
            defer { harness.stop() }

            let codexOnly = try harness.search("", agents: [.codex])
            XCTAssertEqual(codexOnly.results.map(\.agent), [.codex])
            XCTAssertEqual(codexOnly.availableAgents, [.claudeCode, .codex], "The filter's choices ignore the filter itself.")
            XCTAssertFalse(codexOnly.progress.isBuilding)

            let found = try harness.search("kestrel")
            XCTAssertEqual(found.results.map(\.sessionKey), ["claude-feature"])
            XCTAssertEqual(found.results.first?.excerpt?.contains("kestrel"), true)
        }

        func testANegativePageIsRefusedWithoutReachingTheIndex() throws {
            let harness = try makeHarness()
            defer { harness.stop() }

            let response = try harness.send(.searchAgentSessions(.init(query: "", page: -1)))

            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.errorCode, .invalidArgument)
        }

        // MARK: - Project filter

        private func keys(_ result: SpacesDeviceAgentSessionSearchResult) -> Set<String> { Set(result.results.map(\.sessionKey)) }

        func testAProjectFilterKeepsTheConversationsThatOpenInThatProject() throws {
            let harness = try makeHarness()
            defer { harness.stop() }

            let atlas = try harness.search("", projectID: "atlas")
            XCTAssertEqual(keys(atlas), ["claude-feature", "claude-pinned", "claude-worktree"], "A deleted worktree stays with its project.")
            XCTAssertTrue(atlas.results.allSatisfy { $0.workspace.projectID == "atlas" })
            XCTAssertEqual(keys(try harness.search("", projectID: "gone")), ["claude-gone", "claude-crosspin"])
        }

        func testAProjectFilterCombinesWithTheAgentFilterAndAQuery() throws {
            let harness = try makeHarness()
            defer { harness.stop() }

            XCTAssertEqual(keys(try harness.search("kestrel", projectID: "atlas")), ["claude-feature"])
            XCTAssertTrue(try harness.search("kestrel", projectID: "gone").results.isEmpty)
            XCTAssertTrue(try harness.search("", agents: [.codex], projectID: "atlas").results.isEmpty)
            XCTAssertEqual(keys(try harness.search("", agents: [.codex], projectID: "home-project")), [codexMissingThread])
        }

        func testTheHomeFilterKeepsConversationsFromOutsideEveryProjectAndThoseWithoutAFolder() throws {
            let harness = try makeHarness()
            defer { harness.stop() }

            let home = try harness.search("", projectID: "home-project")

            XCTAssertEqual(keys(home), ["claude-elsewhere", "claude-nofolder", codexMissingThread])
            XCTAssertTrue(home.results.allSatisfy { $0.workspace.projectID == "home-project" })
        }

        func testAConversationPinnedInAnotherProjectShowsUnderThePinsProjectOnly() throws {
            let harness = try makeHarness()
            defer { harness.stop() }

            XCTAssertTrue(keys(try harness.search("", projectID: "gone")).contains("claude-crosspin"))
            XCTAssertFalse(keys(try harness.search("", projectID: "atlas")).contains("claude-crosspin"), "Its folder is Atlas's.")
            XCTAssertFalse(keys(try harness.search("", projectID: "home-project")).contains("claude-crosspin"))
        }

        func testAProjectThisDeviceDoesNotHaveMatchesNothingAndTheChoicesStillCome() throws {
            let harness = try makeHarness()
            defer { harness.stop() }

            let result = try harness.search("", projectID: "deleted-project")

            XCTAssertTrue(result.results.isEmpty)
            XCTAssertEqual(result.availableProjects.map(\.id), ["atlas", "gone", "home-project"])
            XCTAssertEqual(result.availableAgents, [.claudeCode, .codex])
        }

        func testTheProjectChoicesListHomeLast() throws {
            let harness = try makeHarness()
            defer { harness.stop() }

            let projects = try harness.search("").availableProjects

            XCTAssertEqual(projects.map(\.id), ["atlas", "gone", "home-project"])
            XCTAssertEqual(projects.map(\.name), ["Atlas", "Gone", "~"])
            XCTAssertEqual(projects.map(\.isHome), [false, false, true])
        }

        // MARK: - Resume

        func testResumingLaunchesInTheMappedWorkspaceThenFocusesWhileItRuns() throws {
            let harness = try makeHarness()
            defer { harness.stop() }

            let resumed = try harness.send(
                .resumeAgentSession(.init(agent: .claudeCode, sessionKey: "claude-feature", workingDirectory: featureDirectory.path)))

            XCTAssertTrue(resumed.ok, resumed.message)
            let launch = try XCTUnwrap(launches.configurations().last)
            XCTAssertTrue(launch.command?.contains("claude --resume claude-feature") == true, launch.command ?? "nil")
            XCTAssertEqual(launch.workingDirectory, featureDirectory.path)
            XCTAssertEqual(launch.workspaceID, "feature-workspace")
            XCTAssertEqual(resumed.sessionID, launch.sessionID)
            XCTAssertEqual(resumed.workspaceID, "feature-workspace")
            XCTAssertEqual(resumed.launchedTerminalSession?.id, launch.sessionID)

            let launchCount = launches.configurations().count
            let again = try harness.send(
                .resumeAgentSession(.init(agent: .claudeCode, sessionKey: "claude-feature", workingDirectory: featureDirectory.path)))

            XCTAssertTrue(again.ok, again.message)
            XCTAssertEqual(again.sessionID, launch.sessionID, "A running conversation is focused, not launched again.")
            XCTAssertNil(again.launchedTerminalSession)
            XCTAssertEqual(launches.configurations().count, launchCount)
            let running = try hit("claude-feature", in: try harness.search(""))
            XCTAssertEqual(running.runningTerminalSessionID, launch.sessionID)
        }

        func testAnAgentThatExitedInALiveShellIsNotRunningAndResumeLaunchesANewSession() throws {
            let harness = try makeHarness()
            defer { harness.stop() }
            let reference = SpacesDeviceResumeAgentSessionRequest(
                agent: .claudeCode, sessionKey: "claude-feature", workingDirectory: featureDirectory.path)
            let first = try harness.send(.resumeAgentSession(reference))
            XCTAssertTrue(first.ok, first.message)
            // The agent quits but its terminal shell stays open: the row is kept `.exited` with its conversation key.
            let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
            let row = try XCTUnwrap(try store.agentWindow(workspaceID: "feature-workspace", terminalTrackingID: try XCTUnwrap(first.sessionID)))
            try store.updateAgentWindowStatus(id: row.id, status: .exited, updatedAt: "2026-06-06T00:00:00Z")

            XCTAssertNil(try hit("claude-feature", in: try harness.search("")).runningTerminalSessionID)
            let again = try harness.send(.resumeAgentSession(reference))

            XCTAssertTrue(again.ok, again.message)
            XCTAssertNotNil(again.launchedTerminalSession, "An exited agent is resumed in a new session, not focused.")
            XCTAssertNotEqual(again.sessionID, first.sessionID)
        }

        func testResumingAnAgentWhoseFolderIsGoneLaunchesInTheWorkspaceDirectory() throws {
            let harness = try makeHarness()
            defer { harness.stop() }

            let resumed = try harness.send(
                .resumeAgentSession(.init(agent: .codex, sessionKey: codexMissingThread, workingDirectory: missingDirectory.path)))

            XCTAssertTrue(resumed.ok, resumed.message)
            let launch = try XCTUnwrap(launches.configurations().last)
            XCTAssertTrue(launch.command?.contains("codex resume \(codexMissingThread)") == true, launch.command ?? "nil")
            XCTAssertEqual(launch.workingDirectory, homeDirectory.path)
            XCTAssertEqual(launch.workspaceID, "home-workspace")
        }

        func testAPinnedConversationWhoseFolderIsGoneResumesWithThePinsCommandInTheWorkspaceDirectory() throws {
            let harness = try makeHarness()
            defer { harness.stop() }
            try SQLiteStore(path: DatabaseLocator.defaultPath()).insertPinnedThread(
                PinnedThreadRecord(
                    id: "pin-codex", workspaceID: "feature-workspace", sessionKey: codexMissingThread, name: "Move plan",
                    launchCommand: "codex --profile work", workingDirectory: missingDirectory.path, pinnedAt: "2026-01-10T11:00:00.000Z"))

            XCTAssertEqual(try hit(codexMissingThread, in: try harness.search("")).resumability, .resumable)
            let resumed = try harness.send(
                .resumeAgentSession(.init(agent: .codex, sessionKey: codexMissingThread, workingDirectory: missingDirectory.path)))

            XCTAssertTrue(resumed.ok, resumed.message)
            let launch = try XCTUnwrap(launches.configurations().last)
            XCTAssertTrue(launch.command?.contains("--profile work") == true, launch.command ?? "nil")
            XCTAssertTrue(launch.command?.contains("resume \(codexMissingThread)") == true, launch.command ?? "nil")
            XCTAssertEqual(launch.workspaceID, "feature-workspace")
            XCTAssertEqual(launch.workingDirectory, featureDirectory.path)
        }

        func testResumingClaudeCodeWithoutItsFolderIsRefusedWithTheSessionID() throws {
            let harness = try makeHarness()
            defer { harness.stop() }

            let response = try harness.send(
                .resumeAgentSession(
                    .init(agent: .claudeCode, sessionKey: "claude-gone", workingDirectory: goneProjectDirectory.appendingPathComponent("old").path)))

            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.errorCode, .invalidArgument)
            XCTAssertTrue(response.message.contains("Folder no longer exists, can't resume"), response.message)
            XCTAssertTrue(response.message.contains("claude-gone"), response.message)
            XCTAssertTrue(launches.configurations().isEmpty)
        }

        // MARK: - Fixtures

        private let codexMissingThread = "01a00000-0000-7000-8000-0000000000c1"

        private func hit(_ key: String, in result: SpacesDeviceAgentSessionSearchResult) throws -> SpacesDeviceAgentSessionHit {
            try XCTUnwrap(result.results.first { $0.sessionKey == key }, "No hit for \(key) in \(result.results.map(\.sessionKey))")
        }

        private func seedDevice() throws {
            for directory in [homeDirectory, atlasDirectory, featureDirectory, goneProjectDirectory, elsewhereDirectory] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try FileManager.default.createDirectory(at: root.appendingPathComponent("gone-main"), withIntermediateDirectories: true)
            let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
            func project(_ id: String, _ name: String, _ dir: String, kind: ProjectKind = .standard) -> ProjectRecord {
                ProjectRecord(
                    id: id, name: name, dir: dir, isGitRepo: false, defaultBranch: nil, kind: kind, setupScript: nil, stopScript: nil, ports: [],
                    processes: [], browserSessions: [])
            }
            func workspace(_ id: String, _ projectID: String, _ dir: String, branch: String?, isDefault: Bool) -> WorkspaceRecord {
                WorkspaceRecord(
                    id: id, projectID: projectID, dir: dir, dirname: nil, branch: branch, isDefault: isDefault, isRunning: false, lastLaunchedAt: nil)
            }
            try store.upsert(project: project("home-project", "~", homeDirectory.path, kind: .home))
            try store.upsert(workspace: workspace("home-workspace", "home-project", homeDirectory.path, branch: nil, isDefault: true))
            try store.upsert(project: project("atlas", "Atlas", atlasDirectory.path))
            try store.upsert(workspace: workspace("atlas-workspace", "atlas", atlasDirectory.path, branch: "main", isDefault: true))
            try store.upsert(workspace: workspace("feature-workspace", "atlas", featureDirectory.path, branch: "feature", isDefault: false))
            // The default workspace lives elsewhere, so a folder under the project's own directory (a worktree
            // that has since been deleted) is contained by no workspace.
            try store.upsert(project: project("gone", "Gone", goneProjectDirectory.path))
            try store.upsert(
                workspace: workspace("gone-workspace", "gone", root.appendingPathComponent("gone-main").path, branch: "main", isDefault: true))
            try store.insertPinnedThread(
                PinnedThreadRecord(
                    id: "pin-1", workspaceID: "feature-workspace", sessionKey: "claude-pinned", name: "Pinned fix",
                    launchCommand: "claude --model opus", workingDirectory: atlasDirectory.path, pinnedAt: "2026-01-10T10:00:00.000Z"))
            try store.insertPinnedThread(
                PinnedThreadRecord(
                    id: "pin-2", workspaceID: "gone-workspace", sessionKey: "claude-crosspin", name: "Cross pin", launchCommand: "claude",
                    workingDirectory: atlasDirectory.path, pinnedAt: "2026-01-10T10:01:00.000Z"))
        }

        /// A throwaway home holding conversations from two agents, indexed before the server starts.
        private func seedIndex() throws {
            let storeHome = root.appendingPathComponent("agent-home")
            let locations = AgentSessionStoreLocations(home: storeHome)
            func claude(_ key: String, cwd: String?, text: String, minute: Int) throws {
                let directory = locations.claudeCodeProjects.appendingPathComponent("-project", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let user = Self.claudeLine(role: "user", text: text, cwd: cwd, minute: minute)
                let reply = Self.claudeLine(role: "assistant", text: "done", cwd: cwd, minute: minute)
                try Data((user + "\n" + reply + "\n").utf8).write(to: directory.appendingPathComponent("\(key).jsonl"))
            }
            try claude("claude-feature", cwd: featureDirectory.path, text: "tidy the kestrel module", minute: 10)
            try claude("claude-gone", cwd: goneProjectDirectory.appendingPathComponent("old").path, text: "port the gone project", minute: 9)
            try claude("claude-elsewhere", cwd: elsewhereDirectory.path, text: "something elsewhere", minute: 8)
            try claude("claude-pinned", cwd: atlasDirectory.path, text: "pinned conversation", minute: 7)
            try claude("claude-worktree", cwd: atlasWorktreeRoot.appendingPathComponent("deleted-feature").path, text: "deleted worktree", minute: 6)
            try claude("claude-nofolder", cwd: nil, text: "no folder recorded", minute: 5)
            try claude("claude-crosspin", cwd: atlasDirectory.path, text: "pinned in another project", minute: 4)

            let day = locations.codexSessions.appendingPathComponent("2026/01/10", isDirectory: true)
            try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
            let meta =
                #"{"timestamp":"2026-01-10T10:00:00.100Z","type":"session_meta","payload":{"id":"\#(codexMissingThread)","cwd":"\#(missingDirectory.path)","source":"cli"}}"#
            let prompt =
                #"{"timestamp":"2026-01-10T10:00:01.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","content":[{"type":"text","text":"codex plan the move"}]}}}"#
            try Data((meta + "\n" + prompt + "\n").utf8).write(
                to: day.appendingPathComponent("rollout-2026-01-10T10-00-00-\(codexMissingThread).jsonl"))

            let index = try AgentSessionIndex(indexURL: root.appendingPathComponent("index/sessions.sqlite"), locations: locations)
            _ = try index.refresh()
            operations = AgentSessionSearchOperations { query, page, agents, folders in
                try index.snapshot(query: query, page: page, agents: agents, folders: folders, isBuilding: false)
            }
        }

        private static func claudeLine(role: String, text: String, cwd: String?, minute: Int) -> String {
            let content = role == "user" ? "\"\(text)\"" : #"[{"type":"text","text":"\#(text)"}]"#
            let cwdField = cwd.map { #","cwd":"\#($0)""# } ?? ""
            return
                #"{"type":"\#(role)","message":{"role":"\#(role)","content":\#(content)},"timestamp":"2026-01-10T10:\#(String(format: "%02d", minute)):00.000Z","entrypoint":"cli"\#(cwdField)}"#
        }

        private struct Harness {
            let server: SpacesDeviceAPIServer
            let client: SpacesDeviceAPIRequestSessionClient
            let clientApp: SpacesDeviceClientApp
            let token: String

            func stop() {
                client.cancel()
                server.stop()
            }

            func send(_ command: SpacesDeviceAPICommand) throws -> SpacesDeviceAPIResponse {
                try client.send(SpacesDeviceAPIRequest(command: command, authToken: token, clientApp: clientApp))
            }

            func search(_ query: String, agents: [CodingAgent]? = nil, projectID: String? = nil) throws -> SpacesDeviceAgentSessionSearchResult {
                let response = try send(.searchAgentSessions(.init(query: query, page: 0, agents: agents, projectID: projectID)))
                XCTAssertTrue(response.ok, response.message)
                return try XCTUnwrap(response.agentSessionSearch)
            }
        }

        private func makeHarness() throws -> Harness {
            let identity = try TerminalServiceTLSIdentityStore.loadOrCreate(root: tlsRoot)
            let pairingStore = SessionSearchPairingStore()
            let recorder = launches!
            let server = SpacesDeviceAPIServer(
                host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore,
                builtInTerminalSessionLauncher: { Self.launchLive($0, recorder: recorder) }, agentSessionSearchOperations: operations)
            try server.start()
            let client = try SpacesDeviceAPIRequestSessionClient(
                resolver: SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint))
            let clientApp = SpacesDeviceClientApp(
                installationID: "agent-session-search-test", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos",
                deviceName: "Mac", appVersion: "1.0")
            return Harness(server: server, client: client, clientApp: clientApp, token: pairingStore.authToken)
        }

        /// Launches like the terminal service does for the parts a resume reads: the persisted launch
        /// configuration, and a runtime state and control socket that make the session read as live.
        private static func launchLive(_ configuration: TerminalSessionLaunchConfiguration, recorder: SessionSearchLaunchRecorder)
            -> TerminalServiceSessionSummary
        {
            if let paths = try? TerminalSessionPaths.forSession(id: configuration.sessionID) {
                try? paths.ensureDirectories()
                try? TerminalSessionPersistence.writeLaunchConfiguration(configuration, paths: paths)
                try? TerminalSessionPersistence.writeRuntimeState(
                    TerminalSessionRuntimeState(
                        sessionID: configuration.sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: 123, state: .running,
                        updatedAt: "2026-06-06T00:00:00Z"), paths: paths)
                FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
            }
            return recorder.launch(configuration)
        }
    }

    private final class SessionSearchLaunchRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [TerminalSessionLaunchConfiguration] = []

        func launch(_ configuration: TerminalSessionLaunchConfiguration) -> TerminalServiceSessionSummary {
            lock.lock()
            stored.append(configuration)
            lock.unlock()
            return TerminalServiceSessionSummary(
                id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory,
                backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy, state: .running, servicePID: 123, childPID: 456,
                controlSocketPath: "/tmp/control-\(configuration.sessionID)", outputPath: "/tmp/output-\(configuration.sessionID)",
                launchConfiguration: configuration)
        }

        func configurations() -> [TerminalSessionLaunchConfiguration] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private final class SessionSearchPairingStore: SpacesDevicePairingStoreProtocol {
        let authToken = "valid-token"

        func issueToken(for _: SpacesDeviceClientApp, presentedToken _: String?) throws -> String { authToken }
        func listDevices() throws -> [SpacesDevicePairedClient] { [] }
        func revoke(installationID _: String) throws {}
        func removeAll() throws {}
        func pushRegistrations() throws -> [String: SpacesDevicePushRegistration] { [:] }
        func setPushRegistration(_: SpacesDevicePushRegistration, forInstallationID _: String) throws {}
        func clearPushRegistration(forInstallationID _: String, matchingCapability _: String?) throws -> SpacesDevicePushRegistration? { nil }
        func authorize(clientApp: SpacesDeviceClientApp?, authToken: String?) throws {
            guard clientApp != nil, authToken == self.authToken else {
                throw NSError(domain: "SpacesDeviceAPIServer", code: 401, userInfo: [NSLocalizedDescriptionKey: "Invalid device auth token."])
            }
        }
        func validate(clientApp _: SpacesDeviceClientApp) throws {}
    }
#endif
