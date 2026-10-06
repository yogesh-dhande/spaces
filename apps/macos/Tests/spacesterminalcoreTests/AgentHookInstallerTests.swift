// The FileManager-subclass test seam relies on Darwin Foundation declaring
// fileExists(atPath:isDirectory:) as an overridable method; swift-corelibs-foundation
// declares it in an extension, which cannot be overridden, so these tests are
// Darwin-only while the installer itself stays cross-platform.
#if canImport(Darwin)
    import Foundation
    import Testing

    @testable import spacesterminalcore

    #if os(Linux)
        import Glibc
    #else
        import Darwin
    #endif

    // Serialized: nearly every test here spawns a real child process (a stub `codex`/shell script) with
    // a fixed deadline. Running dozens of spawners in this suite concurrently starves those deadlines
    // under load (parallel: 15 failures; serialized: 47/47 in 5.2s). `.serialized` only orders tests
    // within this suite, but that is the dominant source of contention.
    @Suite(.serialized) struct AgentHookInstallerTests {
        /// Availability probing reads `PATH`, then the common install directories, then the user's login
        /// shell. Tests pin all three — an empty `PATH`, a `HomeScopedFileManager` that hides executables
        /// outside the temporary home, and a stub shell probe — so no test depends on what is installed on
        /// the developer's machine or spawns a real interactive shell.
        private let environment = ["PATH": ""]

        /// Stands in for the login-shell PATH probe and counts how often it is consulted.
        private final class ShellProbeSpy: @unchecked Sendable {
            private let lock = NSLock()
            private var invocations = 0
            private let directories: [String]

            init(directories: [String] = []) { self.directories = directories }

            var invocationCount: Int {
                lock.lock()
                defer { lock.unlock() }
                return invocations
            }

            var resolver: AgentHookInstaller.ShellPathDirectoryResolver {
                { [self] _, _, _ in
                    lock.lock()
                    invocations += 1
                    lock.unlock()
                    return directories
                }
            }
        }

        private func makeHome() throws -> URL {
            let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(
                "agent-hooks-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            return home
        }

        private func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

        @discardableResult private func install(
            _ kinds: [CodingAgent], home: URL, fileManager: FileManager? = nil, shell: ShellProbeSpy = ShellProbeSpy(),
            codex: FakeCodexAppServer = FakeCodexAppServer(), environment: [String: String]? = nil
        ) throws -> AgentHookInstallOutcome {
            try AgentHookInstaller.install(
                kinds, home: home, fileManager: fileManager ?? HomeScopedFileManager(home: home), environment: environment ?? self.environment,
                shellPathDirectoryResolver: shell.resolver, codexAppServer: codex.launcher)
        }

        private func status(
            home: URL, fileManager: FileManager? = nil, shell: ShellProbeSpy = ShellProbeSpy(), codex: FakeCodexAppServer = FakeCodexAppServer(),
            environment: [String: String]? = nil
        ) -> [AgentHookStatus] {
            AgentHookInstaller.status(
                home: home, fileManager: fileManager ?? HomeScopedFileManager(home: home), environment: environment ?? self.environment,
                shellPathDirectoryResolver: shell.resolver, codexAppServer: codex.launcher)
        }

        @discardableResult private func trust(_ kind: CodingAgent, home: URL, codex: FakeCodexAppServer = FakeCodexAppServer()) throws
            -> AgentHookInstallOutcome
        {
            try AgentHookInstaller.trust(
                kind, home: home, fileManager: HomeScopedFileManager(home: home), environment: environment,
                shellPathDirectoryResolver: ShellProbeSpy().resolver, codexAppServer: codex.launcher)
        }

        /// Availability probing scans real system directories (`/usr/local/bin`, `/opt/homebrew/bin`, …) in
        /// addition to the home under test. A `spaces` or agent CLI installed on the machine running these
        /// tests would otherwise satisfy the probe, so executables outside the temporary home are hidden.
        /// Only the probe is scoped; reads and writes pass straight through.
        private final class HomeScopedFileManager: FileManager {
            private let homePath: String

            init(home: URL) {
                self.homePath = Self.resolved(home.path)
                super.init()
            }

            /// Both sides are symlink-resolved: macOS temp homes have a `/var/...` and a `/private/var/...`
            /// spelling, and the probe's `pwd -P` and the installer's path standardization each produce a
            /// different one for the same file.
            override func isExecutableFile(atPath path: String) -> Bool {
                Self.resolved(path).hasPrefix(homePath + "/") && super.isExecutableFile(atPath: path)
            }

            private static func resolved(_ path: String) -> String {
                guard let resolved = realpath(path, nil) else { return path }
                defer { free(resolved) }
                return String(cString: resolved)
            }
        }

        /// Every install resolves the Spaces CLI to embed in the hook commands, so a home that has agents
        /// but no installed `spaces` cannot install anything. Tests that install give it an installed Spaces
        /// and put the agents in `~/.local/bin`.
        private func makeAgentsAvailable(_ kinds: [CodingAgent], home: URL) throws {
            try makeSpacesCLIAvailable(home: home)
            for name in Set(kinds.flatMap(\.executableNames)) {
                let contents = name == "codex" ? Self.codexFeatureCLIScript : "#!/bin/sh\n"
                try makeExecutable(name: name, directory: home.appendingPathComponent(".local/bin", isDirectory: true), contents: contents)
            }
        }

        /// A small behavioral stand-in for `codex features enable/list`. Product code is tested against
        /// the command boundary; Codex itself owns the TOML parsing and serialization behind it.
        private static let codexFeatureCLIScript = #"""
            #!/bin/sh
            config="$CODEX_HOME/config.toml"
            if [ "$1" = "features" ] && [ "$2" = "enable" ] && [ "$3" = "hooks" ]; then
              if [ -f "$config" ] && grep -Eq '^[[:space:]]*hooks[[:space:]]*=[[:space:]]*true' "$config"; then
                exit 0
              fi
              printf '\n[features]\nhooks = true\n' >> "$config"
              exit 0
            fi
            if [ "$1" = "features" ] && [ "$2" = "list" ]; then
              enabled=false
              if [ -f "$config" ] && grep -Eq '^[[:space:]]*hooks[[:space:]]*=[[:space:]]*true' "$config"; then
                enabled=true
              fi
              printf 'hooks                                stable             %s\n' "$enabled"
              exit 0
            fi
            if [ "$1 $2 $3" = "app-server daemon version" ]; then
              if [ -f "$CODEX_HOME/shared-server-running" ]; then
                printf '{"status":"running","backend":"pid","cliVersion":"0.160.0","appServerVersion":"0.160.0"}\n'
                exit 0
              fi
              printf 'failed to connect to %s/app-server-control.sock\n' "$CODEX_HOME" >&2
              exit 1
            fi
            if [ "$1 $2 $3" = "app-server daemon stop" ]; then
              if [ -f "$CODEX_HOME/shared-server-refuses-to-stop" ]; then
                printf 'daemon is wedged\n' >&2
                exit 1
              fi
              if [ -f "$CODEX_HOME/shared-server-running" ]; then
                rm -f "$CODEX_HOME/shared-server-running"
                printf '{"status":"stopped"}\n'
              else
                printf '{"status":"notRunning"}\n'
              fi
              exit 0
            fi
            printf 'unexpected codex arguments\n' >&2
            exit 64
            """#

        /// Installs Spaces the way the macOS app does: the CLI lives in an app bundle and `~/.spaces/bin/spaces`
        /// links to it. The bundle sits under the fixture home, so no test touches `/Applications`.
        @discardableResult private func makeSpacesCLIAvailable(home: URL, bundleName: String = "Spaces.app") throws -> URL {
            let bundleCLI = try makeExecutable(
                name: AgentHookCommand.spacesExecutableName,
                directory: home.appendingPathComponent("Applications/\(bundleName)/Contents/Resources", isDirectory: true))
            let link = installedCLILink(home: home)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundleCLI)
            return bundleCLI
        }

        private func installedCLILink(home: URL) -> URL { home.appendingPathComponent(".spaces/bin/\(AgentHookCommand.spacesExecutableName)") }

        /// The path hooks name for the installed CLI: the bundle the link points into.
        private func spacesCLIPath(home: URL) -> String { installedCLILink(home: home).resolvingSymlinksInPath().path }

        /// A `spaces` built into a repo checkout, which a repo-built daemon finds first because it prepends
        /// its own executable directory to PATH. Returns the PATH that finds it.
        private func makeDevBuildCLI(home: URL) throws -> (path: String, environment: [String: String]) {
            let directory = home.appendingPathComponent("work/apps/macos/.build/debug", isDirectory: true)
            let cli = try makeExecutable(name: AgentHookCommand.spacesExecutableName, directory: directory)
            return (cli.path, ["PATH": directory.path])
        }

        @discardableResult private func makeExecutable(name: String, directory: URL, contents: String = "#!/bin/sh\n") throws -> URL {
            let file = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            return file
        }

        private final class StubFileManager: FileManager {
            let existingPaths: Set<String>
            let executablePaths: Set<String>

            init(existingPaths: Set<String> = [], executablePaths: Set<String> = []) {
                self.existingPaths = existingPaths
                self.executablePaths = executablePaths
                super.init()
            }

            override func fileExists(atPath path: String) -> Bool { existingPaths.contains(path) }

            override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
                if existingPaths.contains(path) {
                    isDirectory?.pointee = true
                    return true
                }
                return false
            }

            override func isExecutableFile(atPath path: String) -> Bool { executablePaths.contains(path) }
        }

        // MARK: - Idempotency (the core contract: replay never duplicates)

        @Test func installIsByteIdenticalOnReplayForEveryAgent() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable(CodingAgent.allCases, home: home)

            try install(CodingAgent.allCases, home: home)
            let files = [
                home.appendingPathComponent(".claude/settings.json"), home.appendingPathComponent(".codex/hooks.json"),
                home.appendingPathComponent(".codex/config.toml"), home.appendingPathComponent(".config/opencode/plugin/spaces-agent-signal.js"),
            ]
            let firstPass = files.map(read)

            let replayOutcome = try install(CodingAgent.allCases, home: home)
            let secondPass = files.map(read)

            #expect(replayOutcome.failures.isEmpty)
            #expect(firstPass == secondPass)
            for contents in firstPass { #expect(!contents.isEmpty) }
        }

        @Test func replayDoesNotDuplicateHookEntries() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.claudeCode], home: home)

            for _ in 0..<3 { try install([.claudeCode], home: home) }

            let contents = read(home.appendingPathComponent(".claude/settings.json"))
            // Exactly one Spaces command per mapped event across three installs.
            let markerCount = contents.components(separatedBy: "# \(AgentHookCommand.marker)").count - 1
            #expect(markerCount == CodingAgent.claudeCode.jsonEventBindings.count)
        }

        // MARK: - Preserving the user's existing config

        @Test func preservesUnrelatedClaudeSettingsAndHooks() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.claudeCode], home: home)
            let settings = home.appendingPathComponent(".claude/settings.json")
            try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            let existing = """
                {
                  "model": "opus",
                  "hooks": {
                    "Notification": [
                      { "matcher": "", "hooks": [ { "type": "command", "command": "/opt/other/tool notify" } ] }
                    ]
                  }
                }
                """
            try existing.write(to: settings, atomically: true, encoding: .utf8)

            try install([.claudeCode], home: home)
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]

            #expect(object["model"] as? String == "opus")
            let hooks = object["hooks"] as! [String: Any]
            // The user's unrelated Notification hook survives untouched.
            let notification = hooks["Notification"] as! [[String: Any]]
            let notifyCommand = ((notification[0]["hooks"] as! [[String: Any]])[0]["command"]) as! String
            #expect(notifyCommand == "/opt/other/tool notify")
            // Spaces events were added.
            #expect(hooks["SessionStart"] != nil)
            #expect(hooks["Stop"] != nil)
        }

        /// The seeded Spaces entry carries a stale `spaces` path, as it would after the CLI moved. Reinstall
        /// must leave exactly one Spaces entry, pointing at the path resolved now, and keep the user's own
        /// command in the same hook group.
        @Test func reinstallPreservesUserHookEntriesInsideMixedHookGroup() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.claudeCode], home: home)
            let settings = home.appendingPathComponent(".claude/settings.json")
            try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            let userCommand = "/opt/user/session-start"
            let staleCommand = AgentHookCommand.signalCommand(event: .initialize, spacesExecutablePath: "/old/bin/spaces")
            let existing = """
                {
                  "hooks": {
                    "SessionStart": [
                      {
                        "matcher": "",
                        "hooks": [
                          { "type": "command", "command": "\(staleCommand)" },
                          { "type": "command", "command": "\(userCommand)" }
                        ]
                      }
                    ]
                  }
                }
                """
            try existing.write(to: settings, atomically: true, encoding: .utf8)

            try install([.claudeCode], home: home)
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
            let hooks = object["hooks"] as! [String: Any]
            let groups = hooks["SessionStart"] as! [[String: Any]]
            let commands = groups.flatMap { group in ((group["hooks"] as? [[String: Any]]) ?? []).compactMap { $0["command"] as? String } }

            #expect(commands.contains(userCommand))
            let spacesCommands = commands.filter(AgentHookCommand.isSpacesOwned)
            #expect(spacesCommands.count == 1)
            #expect(spacesCommands.first?.contains(spacesCLIPath(home: home)) == true)
        }

        /// Agent configs are commonly symlinked into a dotfiles repo. An atomic write to the link path
        /// would replace the link with a regular file and silently detach the user's managed config.
        @Test func installWritesThroughSymlinkedJSONConfigAndKeepsTheLink() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.claudeCode], home: home)

            let dotfiles = home.appendingPathComponent("dotfiles", isDirectory: true)
            try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
            let managedSettings = dotfiles.appendingPathComponent("settings.json")
            try "{ \"model\": \"opus\" }".write(to: managedSettings, atomically: true, encoding: .utf8)

            let settings = home.appendingPathComponent(".claude/settings.json")
            try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: managedSettings)

            try install([.claudeCode], home: home)

            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: settings.path)) == managedSettings.path)
            #expect(read(managedSettings).contains(AgentHookCommand.marker))
            #expect(read(managedSettings).contains("opus"))
        }

        /// A dangling link (dotfiles repo not cloned yet, unmounted volume) points at nothing worth
        /// preserving. The install must replace the dead link in place, not create directories at a
        /// destination the user never populated — and never fail, which would defer the install forever.
        @Test func installReplacesADanglingSymlinkInsteadOfFollowingIt() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.claudeCode], home: home)

            let settings = home.appendingPathComponent(".claude/settings.json")
            try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            let missingDestination = home.appendingPathComponent("not-cloned/claude/settings.json")
            try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: missingDestination)

            try install([.claudeCode], home: home)

            #expect(read(settings).contains(AgentHookCommand.marker))
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: settings.path)) == nil)  // the dead link is gone
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("not-cloned").path))
        }

        @Test func installReplacesASymlinkCycleInsteadOfLoopingOrFollowingIt() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.claudeCode], home: home)

            let settings = home.appendingPathComponent(".claude/settings.json")
            let other = home.appendingPathComponent(".claude/other.json")
            try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: other)
            try FileManager.default.createSymbolicLink(at: other, withDestinationURL: settings)

            try install([.claudeCode], home: home)

            #expect(read(settings).contains(AgentHookCommand.marker))
        }

        @Test func malformedConfigIsNotOverwritten() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.claudeCode], home: home)
            let settings = home.appendingPathComponent(".claude/settings.json")
            try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            let garbage = "{ this is not json"
            try garbage.write(to: settings, atomically: true, encoding: .utf8)

            let outcome = try install([.claudeCode], home: home)

            #expect(outcome.failures.map(\.kind) == [.claudeCode])
            #expect(outcome.agents.first { $0.kind == .claudeCode }?.installState == .notInstalled)
            #expect(read(settings) == garbage)
        }

        @Test func nonObjectHooksConfigIsNotOverwritten() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.claudeCode], home: home)
            let settings = home.appendingPathComponent(".claude/settings.json")
            try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            let existing = "{ \"hooks\": [\"user-managed\"] }"
            try existing.write(to: settings, atomically: true, encoding: .utf8)

            let outcome = try install([.claudeCode], home: home)

            #expect(outcome.failures.map(\.kind) == [.claudeCode])
            #expect(outcome.failures.first?.message.localizedStandardContains("unsupported JSON value") == true)
            #expect(read(settings) == existing)
        }

        @Test func nonArrayMappedEventIsNotOverwritten() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.claudeCode], home: home)
            let settings = home.appendingPathComponent(".claude/settings.json")
            try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            let existing = "{ \"hooks\": { \"SessionStart\": { \"command\": \"user-managed\" } } }"
            try existing.write(to: settings, atomically: true, encoding: .utf8)

            let outcome = try install([.claudeCode], home: home)

            #expect(outcome.failures.map(\.kind) == [.claudeCode])
            #expect(outcome.failures.first?.message.contains("hooks.SessionStart") == true)
            #expect(read(settings) == existing)
        }

        @Test func opencodeInstallDoesNotOverwriteAnUnmanagedPlugin() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.opencode], home: home)
            let plugin = home.appendingPathComponent(".config/opencode/plugin/spaces-agent-signal.js")
            try FileManager.default.createDirectory(at: plugin.deletingLastPathComponent(), withIntermediateDirectories: true)
            let existing = "export const UserPlugin = async () => ({})\n"
            try existing.write(to: plugin, atomically: true, encoding: .utf8)

            let outcome = try install([.opencode], home: home)

            #expect(outcome.failures.map(\.kind) == [.opencode])
            #expect(outcome.failures.first?.message.localizedStandardContains("not managed by Spaces") == true)
            #expect(read(plugin) == existing)
        }

        // MARK: - Codex trust

        /// The name Codex gives `hooksFileURL` in a state table: its home canonicalized the way
        /// `realpath(3)` reports it, with the file name appended. A temporary home reached through
        /// `/var` is therefore named under `/private/var`, which is what Codex records and what
        /// Foundation's own symlink resolution would undo.
        private func codexKeyPath(_ hooksFileURL: URL) -> String {
            FakeCodexAppServer.hooksFileKeyPath(codexHome: hooksFileURL.deletingLastPathComponent())
        }

        /// The `config.toml` tables Codex writes once the user trusts the Spaces entries of
        /// `hooksFileURL` at the text the file holds now, built from the file itself so the coordinates
        /// follow whatever else the user hooks. Written independently of the product's own key
        /// derivation, so the two have to agree.
        private func codexTrustTables(hooksFileURL: URL) throws -> String {
            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksFileURL)) as! [String: Any]
            let hooks = root["hooks"] as! [String: Any]
            let keyPath = codexKeyPath(hooksFileURL)
            var commandsByKey: [String: String] = [:]
            for (eventName, value) in hooks {
                let event = eventName.reduce(into: "") { snake, character in
                    if character.isUppercase, !snake.isEmpty { snake.append("_") }
                    snake.append(contentsOf: character.lowercased())
                }
                for (groupIndex, group) in (value as! [[String: Any]]).enumerated() {
                    for (hookIndex, entry) in ((group["hooks"] as? [[String: Any]]) ?? []).enumerated() {
                        guard let command = entry["command"] as? String, AgentHookCommand.isSpacesOwned(command) else { continue }
                        commandsByKey["\(keyPath):\(event):\(groupIndex):\(hookIndex)"] = command
                    }
                }
            }
            return FakeCodexAppServer.trustTables(commandsByKey)
        }

        /// What Codex lists for the codex home of `home`.
        private func codexListing(home: URL) throws -> [AgentHookCodexListedHook] {
            try AgentHookCodexAppServer.withSession(
                executablePath: "codex", codexHome: home.appendingPathComponent(".codex", isDirectory: true), timeoutSeconds: 5,
                launcher: FakeCodexAppServer().launcher
            ) { try $0.listHooks() }
        }

        private func codexStatus(home: URL, codex: FakeCodexAppServer = FakeCodexAppServer()) -> AgentHookStatus? {
            status(home: home, codex: codex).first { $0.kind == .codex }
        }

        private func codexInstallState(home: URL) -> AgentHookInstallState? { codexStatus(home: home)?.installState }

        /// `config.toml` without the `[mcp_servers.spaces]` table, which an install moves to the new CLI path.
        private func withoutSpacesMCPServer(_ config: String) -> String {
            var skipping = false
            return config.components(separatedBy: "\n").filter { line in
                if line.hasPrefix("[") { skipping = line == "[mcp_servers.spaces]" }
                return !skipping
            }.joined(separator: "\n")
        }

        /// Each step of the Codex row, in the order the user meets them: nothing installed, entries an
        /// older Spaces wrote (Update), entries Codex has not trusted (Trust, listing exactly this
        /// device's commands), trusted, and switched off in Codex afterwards.
        @Test func theCodexRowRunsThroughEveryStateFromNotInstalledToSwitchedOff() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.codex], home: home)
            let hooksFileURL = home.appendingPathComponent(".codex/hooks.json")
            let configURL = home.appendingPathComponent(".codex/config.toml")
            #expect(codexInstallState(home: home) == .notInstalled)

            try install([.codex], home: home)
            let previousRelease = read(hooksFileURL).replacingOccurrences(
                of: AgentHookCommand.versionedMarker(), with: AgentHookCommand.versionedMarker(AgentHookCommand.hookVersion - 1))
            try previousRelease.write(to: hooksFileURL, atomically: true, encoding: .utf8)
            #expect(codexInstallState(home: home) == .outdated)

            try install([.codex], home: home)
            let awaiting = try #require(codexStatus(home: home))
            #expect(awaiting.installState == .awaitingTrust)
            #expect(
                awaiting.untrustedEntries
                    == CodingAgent.codex.jsonEventBindings.map {
                        AgentHookEntry(
                            eventName: $0.eventName,
                            command: AgentHookCommand.signalCommand(event: $0.event, spacesExecutablePath: spacesCLIPath(home: home)))
                    })

            let trusted = try trust(.codex, home: home)
            #expect(trusted.failures.isEmpty)
            #expect(
                trusted.agents.first { $0.kind == .codex }
                    == AgentHookStatus(kind: .codex, displayName: "Codex", available: true, installState: .current, sharedServerRunning: false))

            let keyPath = codexKeyPath(hooksFileURL)
            try read(configURL).replacingOccurrences(
                of: "[hooks.state.\"\(keyPath):stop:0:0\"]\n", with: "[hooks.state.\"\(keyPath):stop:0:0\"]\nenabled = false\n"
            ).write(to: configURL, atomically: true, encoding: .utf8)
            #expect(codexInstallState(home: home) == .disabledByAgent)
        }

        /// A status read asks Codex only once the hooks file and the `hooks` feature are current, and
        /// then exactly once, so an agent with nothing to trust never costs an app-server.
        @Test func statusAsksCodexOnlyOnceItsFilesAreCurrent() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.codex], home: home)
            let codex = FakeCodexAppServer()

            _ = status(home: home, codex: codex)
            #expect(codex.launchCount == 0)

            try install([.codex], home: home)
            _ = status(home: home, codex: codex)
            #expect(codex.launchCount == 1)
        }

        /// Codex's refusal comes back as Codex's own failure entry beside fresh status, so the row can say
        /// why and still offer the trust again.
        @Test func aTrustCodexRefusesIsReportedAsCodexsFailure() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.codex], home: home)
            try install([.codex], home: home)

            let outcome = try trust(
                .codex, home: home, codex: FakeCodexAppServer(behavior: .rejects(method: "hooks/list", message: "unknown variant")))

            #expect(outcome.failures == [AgentHookInstallFailure(kind: .codex, message: "Codex refused hooks/list (unknown variant)")])
            #expect(outcome.agents.first { $0.kind == .codex }?.installState == .awaitingTrust)
        }

        @Test func trustingAnAgentThatKeepsNoTrustIsItsFailure() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.claudeCode], home: home)

            let outcome = try trust(.claudeCode, home: home)

            #expect(outcome.failures.map(\.kind) == [.claudeCode])
        }

        @Test func trustFailsWhenTheSpacesCLIIsNotFound() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            #expect(throws: AgentHookInstallerError.spacesCLINotFound) { try trust(.codex, home: home) }
        }

        /// The user trusted exactly this text, so writing the same text back is no reason to ask again:
        /// clicking Install twice, or an install that only re-ensures the feature flag, leaves Codex's
        /// trust standing and the row current.
        @Test func reinstallingUnchangedHooksKeepsCodexsTrust() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.codex], home: home)
            let configURL = home.appendingPathComponent(".codex/config.toml")
            try install([.codex], home: home)
            try trust(.codex, home: home)
            let trustedConfig = read(configURL)
            #expect(codexInstallState(home: home) == .current)

            let outcome = try install([.codex], home: home)

            #expect(outcome.agents.first { $0.kind == .codex }?.installState == .current)
            #expect(read(configURL) == trustedConfig)
        }

        /// A rewrite that changes the text, here because the Spaces CLI moved, leaves Codex's records as
        /// they were. Codex itself sees that the trusted text is gone and asks about the new commands,
        /// and the user's approval of their own hook still names that hook.
        @Test func reinstallingForAMovedSpacesCLIAsksForTrustInTheNewCommandsAndLeavesCodexsRecordsAlone() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.codex], home: home)
            let hooksFileURL = home.appendingPathComponent(".codex/hooks.json")
            let configURL = home.appendingPathComponent(".codex/config.toml")
            try FileManager.default.createDirectory(at: hooksFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "{\"hooks\":{\"Stop\":[{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"my-own-stop-hook\"}]}]}}".write(
                to: hooksFileURL, atomically: true, encoding: .utf8)
            try install([.codex], home: home)
            try trust(.codex, home: home)
            let userTable = FakeCodexAppServer.trustTables(["\(codexKeyPath(hooksFileURL)):stop:0:0": "my-own-stop-hook"])
            try (read(configURL) + userTable).write(to: configURL, atomically: true, encoding: .utf8)
            let approved = withoutSpacesMCPServer(read(configURL))

            try makeSpacesCLIAvailable(home: home, bundleName: "Moved.app")
            let movedCLI = URL(fileURLWithPath: spacesCLIPath(home: home))
            #expect(codexInstallState(home: home) == .outdated)

            try install([.codex], home: home)

            #expect(withoutSpacesMCPServer(read(configURL)) == approved)
            #expect(try codexListing(home: home).first { $0.command == "my-own-stop-hook" }?.isTrusted == true)
            let awaiting = try #require(codexStatus(home: home))
            #expect(awaiting.installState == .awaitingTrust)
            #expect(awaiting.untrustedEntries.count == CodingAgent.codex.jsonEventBindings.count)
            #expect(awaiting.untrustedEntries.allSatisfy { $0.command.hasPrefix("'\(movedCLI.path)'") })
            try trust(.codex, home: home)
            #expect(codexInstallState(home: home) == .current)
        }

        /// A `hookVersion` bump changes the text of every Spaces entry. Codex compares the hash it
        /// recorded with the text the file holds, so trusted entries read untrusted until the user trusts
        /// the new text, with nothing for Spaces to remove from `config.toml`.
        @Test func aHookUpdateReadsAwaitingTrustUntilTheChangedHooksAreTrustedAgain() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.codex], home: home)
            let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
            let hooksFileURL = codexHome.appendingPathComponent("hooks.json")
            let configURL = codexHome.appendingPathComponent("config.toml")

            // A previous Spaces release's hooks, trusted in Codex and reporting normally.
            try install([.codex], home: home)
            let previousRelease = read(hooksFileURL).replacingOccurrences(
                of: AgentHookCommand.versionedMarker(), with: AgentHookCommand.versionedMarker(AgentHookCommand.hookVersion - 1))
            try previousRelease.write(to: hooksFileURL, atomically: true, encoding: .utf8)
            try (read(configURL) + codexTrustTables(hooksFileURL: hooksFileURL)).write(to: configURL, atomically: true, encoding: .utf8)
            let approved = read(configURL)
            #expect(codexInstallState(home: home) == .outdated)

            try install([.codex], home: home)

            #expect(read(configURL) == approved)
            let awaiting = try #require(codexStatus(home: home))
            #expect(awaiting.installState == .awaitingTrust)
            #expect(awaiting.untrustedEntries.count == CodingAgent.codex.jsonEventBindings.count)
            try trust(.codex, home: home)
            #expect(codexInstallState(home: home) == .current)
        }

        /// Codex keeps a hook's switch-off in the same record as its trust, so the update leaves that
        /// record alone and the hook the user switched off stays off, with the row saying so rather than
        /// asking for a trust.
        @Test func aHookUpdateKeepsAHookSwitchedOffInCodexSwitchedOff() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.codex], home: home)
            let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
            let hooksFileURL = codexHome.appendingPathComponent("hooks.json")
            let configURL = codexHome.appendingPathComponent("config.toml")

            // A previous Spaces release's hooks, trusted in Codex, with the Stop hook switched off there.
            try install([.codex], home: home)
            let previousRelease = read(hooksFileURL).replacingOccurrences(
                of: AgentHookCommand.versionedMarker(), with: AgentHookCommand.versionedMarker(AgentHookCommand.hookVersion - 1))
            try previousRelease.write(to: hooksFileURL, atomically: true, encoding: .utf8)
            let stopTable = "[hooks.state.\"\(codexKeyPath(hooksFileURL)):stop:0:0\"]\n"
            let switchedOff = (read(configURL) + (try codexTrustTables(hooksFileURL: hooksFileURL))).replacingOccurrences(
                of: stopTable, with: stopTable + "enabled = false\n")
            try switchedOff.write(to: configURL, atomically: true, encoding: .utf8)

            try install([.codex], home: home)

            #expect(read(configURL) == switchedOff)
            #expect(
                codexStatus(home: home)
                    == AgentHookStatus(
                        kind: .codex, displayName: "Codex", available: true, installState: .disabledByAgent, sharedServerRunning: false))
            let stop = try #require(try codexListing(home: home).first { $0.key == "\(codexKeyPath(hooksFileURL)):stop:0:0" })
            #expect(!stop.enabled)
            #expect(AgentHookCommand.isCurrent(stop.command ?? ""))
        }

        /// Codex names a hook by its position inside its event, so a rewrite that moved the Spaces group
        /// past a hook of the user's own would leave that hook standing on the Spaces entry's record and
        /// send the user to review a hook they never touched. The rewrite keeps the index it holds.
        @Test func reinstallingKeepsTheSpacesGroupWhereItSitsAmongTheUsersOwnHooks() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.codex], home: home)
            let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
            let hooksFileURL = codexHome.appendingPathComponent("hooks.json")
            let configURL = codexHome.appendingPathComponent("config.toml")

            // A previous release's install, with a hook of the user's own added to the same event after it.
            try install([.codex], home: home)
            var root = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksFileURL)) as! [String: Any]
            var hooks = root["hooks"] as! [String: Any]
            var stop = hooks["Stop"] as! [[String: Any]]
            stop.append(["matcher": "", "hooks": [["type": "command", "command": "my-own-stop-hook"]]])
            hooks["Stop"] = stop
            root["hooks"] = hooks
            try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: hooksFileURL)
            let previousRelease = read(hooksFileURL).replacingOccurrences(
                of: AgentHookCommand.versionedMarker(), with: AgentHookCommand.versionedMarker(AgentHookCommand.hookVersion - 1))
            try previousRelease.write(to: hooksFileURL, atomically: true, encoding: .utf8)

            // Both hooks trusted in Codex: the Spaces group at index 0, the user's at index 1.
            let keyPath = codexKeyPath(hooksFileURL)
            let userTable = FakeCodexAppServer.trustTables(["\(keyPath):stop:1:0": "my-own-stop-hook"])
            try (read(configURL) + (try codexTrustTables(hooksFileURL: hooksFileURL)) + userTable).write(
                to: configURL, atomically: true, encoding: .utf8)

            try install([.codex], home: home)

            let rewritten = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksFileURL)) as! [String: Any]
            let groups = (rewritten["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
            #expect(groups.count == 2)
            let spacesCommand = (groups[0]["hooks"] as! [[String: Any]])[0]["command"] as! String
            #expect(AgentHookCommand.isSpacesOwned(spacesCommand))
            #expect(AgentHookCommand.isCurrent(spacesCommand))
            #expect((groups[1]["hooks"] as! [[String: Any]])[0]["command"] as! String == "my-own-stop-hook")

            // The user's approval still names their own hook, so Codex still trusts it.
            let listing = try codexListing(home: home)
            #expect(listing.first { $0.key == "\(keyPath):stop:1:0" }?.command == "my-own-stop-hook")
            #expect(listing.first { $0.key == "\(keyPath):stop:1:0" }?.isTrusted == true)
            #expect(codexInstallState(home: home) == .awaitingTrust)
        }

        /// The same rule one level down: a user who puts a hook of their own in the group Spaces wrote
        /// gives every entry after it a hook index, so a rewrite that lifted the Spaces entry out and
        /// appended a group of its own would renumber their later entries onto records describing other
        /// hooks. The replacement goes back into the slot it held.
        @Test func reinstallingKeepsTheSpacesEntryAtItsHookIndexInsideAGroupTheUserAlsoHooks() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.codex], home: home)
            let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
            let hooksFileURL = codexHome.appendingPathComponent("hooks.json")
            let configURL = codexHome.appendingPathComponent("config.toml")

            // A previous release's install, with hooks of the user's own added either side of the Spaces
            // entry inside the group it wrote.
            try install([.codex], home: home)
            var root = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksFileURL)) as! [String: Any]
            var hooks = root["hooks"] as! [String: Any]
            var stop = hooks["Stop"] as! [[String: Any]]
            var group = stop[0]
            let spacesEntry = (group["hooks"] as! [[String: Any]])[0]
            group["hooks"] = [
                ["type": "command", "command": "my-own-first-stop-hook"], spacesEntry, ["type": "command", "command": "my-own-last-stop-hook"],
            ]
            stop[0] = group
            hooks["Stop"] = stop
            root["hooks"] = hooks
            try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: hooksFileURL)
            let previousRelease = read(hooksFileURL).replacingOccurrences(
                of: AgentHookCommand.versionedMarker(), with: AgentHookCommand.versionedMarker(AgentHookCommand.hookVersion - 1))
            try previousRelease.write(to: hooksFileURL, atomically: true, encoding: .utf8)

            // All three hooks trusted in Codex, each one named by its index inside the group.
            let keyPath = codexKeyPath(hooksFileURL)
            let userTables = FakeCodexAppServer.trustTables([
                "\(keyPath):stop:0:0": "my-own-first-stop-hook", "\(keyPath):stop:0:2": "my-own-last-stop-hook",
            ])
            try (read(configURL) + (try codexTrustTables(hooksFileURL: hooksFileURL)) + userTables).write(
                to: configURL, atomically: true, encoding: .utf8)

            try install([.codex], home: home)

            let rewritten = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksFileURL)) as! [String: Any]
            let groups = (rewritten["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
            #expect(groups.count == 1, "The rewrite reuses the group the entry sits in rather than adding one.")
            let commands = (groups[0]["hooks"] as! [[String: Any]]).map { $0["command"] as! String }
            #expect(commands.count == 3)
            #expect(commands.first == "my-own-first-stop-hook")
            #expect(commands.last == "my-own-last-stop-hook")
            #expect(AgentHookCommand.isSpacesOwned(commands[1]))
            #expect(AgentHookCommand.isCurrent(commands[1]))

            // Both of the user's approvals still name their own hooks, because neither hook moved.
            let trustedUserHooks = try codexListing(home: home).filter { $0.isTrusted }.compactMap(\.command)
            #expect(Set(trustedUserHooks) == ["my-own-first-stop-hook", "my-own-last-stop-hook"])
            #expect(codexInstallState(home: home) == .awaitingTrust)
        }

        // MARK: - The Spaces MCP server entry

        private func codexMCPEntry(home: URL) -> [String: Any]? {
            FakeCodexAppServer.mcpServerEntry(configURL: home.appendingPathComponent(".codex/config.toml"))
        }

        @Test func codexInstallRegistersTheSpacesMCPServerWithTheCallerEnvVars() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.codex], home: home)

            try install([.codex], home: home)

            let entry = try #require(codexMCPEntry(home: home))
            #expect(entry["command"] as? String == spacesCLIPath(home: home))
            #expect(entry["args"] as? [String] == ["mcp"])
            #expect(entry["env_vars"] as? [String] == ["SPACES_TERMINAL_TRACKING_ID", "SPACES_AUTOMATION_RUN_ID"])
        }

        @Test func codexInstallKeepsTheUsersOwnEnvVarsOnTheSpacesMCPServer() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.codex], home: home)
            let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
            try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
            try FakeCodexAppServer.mcpServerTable([(key: "env_vars", json: "[\"MY_VAR\"]")]).write(
                to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

            try install([.codex], home: home)

            #expect(codexMCPEntry(home: home)?["env_vars"] as? [String] == ["MY_VAR", "SPACES_TERMINAL_TRACKING_ID", "SPACES_AUTOMATION_RUN_ID"])
        }

        /// A user whose Codex has no `spaces` entry, or one from before the env vars, is offered setup
        /// again, and setup brings the row back to a state Codex can then be asked to trust.
        @Test func aMissingOrStaleSpacesMCPServerEntryReadsOutdatedUntilInstallWritesIt() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.codex], home: home)
            try install([.codex], home: home)
            try trust(.codex, home: home)
            #expect(codexInstallState(home: home) == .current)

            let configURL = home.appendingPathComponent(".codex/config.toml")
            let withoutEntry = withoutSpacesMCPServer(read(configURL))
            try withoutEntry.write(to: configURL, atomically: true, encoding: .utf8)
            #expect(codexInstallState(home: home) == .outdated)

            try
                (withoutEntry
                + FakeCodexAppServer.mcpServerTable([(key: "command", json: "\"\(spacesCLIPath(home: home))\""), (key: "args", json: "[\"mcp\"]")]))
                .write(to: configURL, atomically: true, encoding: .utf8)
            #expect(codexInstallState(home: home) == .outdated)

            try install([.codex], home: home)
            #expect(codexInstallState(home: home) == .current)
        }

        // MARK: - Codex's shared server

        @Test func statusReportsWhetherCodexsSharedServerIsRunning() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.codex], home: home)
            let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
            try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)

            #expect(codexStatus(home: home)?.sharedServerRunning == false)

            try "".write(to: codexHome.appendingPathComponent("shared-server-running"), atomically: true, encoding: .utf8)
            #expect(codexStatus(home: home)?.sharedServerRunning == true)
            #expect(status(home: home).filter { $0.kind != .codex }.allSatisfy { $0.sharedServerRunning == nil })
        }

        @Test func statusDoesNotProbeTheSharedServerWhenCodexIsNotDetected() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            #expect(codexStatus(home: home)?.available == false)
            #expect(codexStatus(home: home)?.sharedServerRunning == nil)
        }

        @Test func stoppingCodexsSharedServerStopsItAndReturnsFreshStatus() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.codex], home: home)
            let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
            try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
            try "".write(to: codexHome.appendingPathComponent("shared-server-running"), atomically: true, encoding: .utf8)

            let outcome = AgentHookInstaller.stopCodexSharedServer(
                home: home, fileManager: HomeScopedFileManager(home: home), environment: environment,
                shellPathDirectoryResolver: ShellProbeSpy().resolver, codexAppServer: FakeCodexAppServer().launcher)

            #expect(outcome.failures.isEmpty)
            #expect(outcome.agents.first { $0.kind == .codex }?.sharedServerRunning == false)
            #expect(!FileManager.default.fileExists(atPath: codexHome.appendingPathComponent("shared-server-running").path))
        }

        @Test func stoppingCodexsSharedServerWhenNothingRunsSucceeds() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.codex], home: home)
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)

            let outcome = AgentHookInstaller.stopCodexSharedServer(
                home: home, fileManager: HomeScopedFileManager(home: home), environment: environment,
                shellPathDirectoryResolver: ShellProbeSpy().resolver, codexAppServer: FakeCodexAppServer().launcher)

            #expect(outcome.failures.isEmpty)
        }

        @Test func aStopCodexRefusesIsReportedAsCodexsFailureAlongsideFreshStatus() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.codex], home: home)
            let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
            try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
            for name in ["shared-server-running", "shared-server-refuses-to-stop"] {
                try "".write(to: codexHome.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }

            let outcome = AgentHookInstaller.stopCodexSharedServer(
                home: home, fileManager: HomeScopedFileManager(home: home), environment: environment,
                shellPathDirectoryResolver: ShellProbeSpy().resolver, codexAppServer: FakeCodexAppServer().launcher)

            #expect(outcome.failures.map(\.kind) == [.codex])
            #expect(outcome.failures.first?.message.contains("daemon is wedged") == true)
            #expect(outcome.agents.first { $0.kind == .codex }?.sharedServerRunning == true)
        }

        @Test func stoppingCodexsSharedServerWithoutCodexIsCodexsFailure() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }

            let outcome = AgentHookInstaller.stopCodexSharedServer(
                home: home, fileManager: HomeScopedFileManager(home: home), environment: environment,
                shellPathDirectoryResolver: ShellProbeSpy().resolver, codexAppServer: FakeCodexAppServer().launcher)

            #expect(outcome.failures.map(\.kind) == [.codex])
        }

        // MARK: - Codex feature command

        @Test func codexInstallUsesResolvedCLIAndTargetsTheManagedCodexHome() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeSpacesCLIAvailable(home: home)
            let script = Self.codexFeatureCLIScript.replacingOccurrences(
                of: "#!/bin/sh\n", with: "#!/bin/sh\nprintf '%s|%s\\n' \"$*\" \"$CODEX_HOME\" >> \"$CODEX_HOME/invocations\"\n")
            try makeExecutable(name: "codex", directory: home.appendingPathComponent(".local/bin", isDirectory: true), contents: script)

            let outcome = try install([.codex], home: home)
            let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
            let invocations = read(codexHome.appendingPathComponent("invocations"))

            #expect(outcome.failures.isEmpty)
            // A freshly written `hooks.json` is one Codex has never been asked to trust, so the install
            // lands on `awaitingTrust` rather than `current`: the entries are there and cannot fire yet.
            #expect(outcome.agents.first { $0.kind == .codex }?.installState == .awaitingTrust)
            #expect(invocations.contains("features enable hooks|\(codexHome.path)"))
            #expect(invocations.contains("features list|\(codexHome.path)"))
        }

        @Test func codexFeatureCommandsCanResolveARuntimeBesideTheResolvedCLI() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let runtimeDirectory = home.appendingPathComponent(".fnm/node-versions/v24/installation/bin", isDirectory: true)
            let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
            try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
            let executable = try makeExecutable(name: "codex", directory: runtimeDirectory, contents: "#!/usr/bin/env node\n")
            try makeExecutable(
                name: "node", directory: runtimeDirectory,
                contents: #"""
                    #!/bin/sh
                    shift
                    if [ "$1 $2 $3" = "features enable hooks" ]; then
                      exit 0
                    fi
                    if [ "$1 $2" = "features list" ]; then
                      printf 'hooks stable true\n'
                      exit 0
                    fi
                    exit 64
                    """#)

            try AgentHookCodexFeatureToggle.ensureEnabled(executablePath: executable.path, codexHome: codexHome)
        }

        @Test func codexFeatureListParserReadsTheNamedFeaturesEffectiveState() {
            let enabled = """
                apps                                 stable             true
                hooks                                stable             true
                experimental_feature                 under development false
                """
            #expect(AgentHookCodexFeatureToggle.featuresListHasHooksEnabled(enabled))
            #expect(
                !AgentHookCodexFeatureToggle.featuresListHasHooksEnabled(
                    enabled.replacingOccurrences(of: "hooks                                stable             true", with: "hooks stable false")))
            #expect(!AgentHookCodexFeatureToggle.featuresListHasHooksEnabled("other_hooks stable true\n"))
        }

        @Test func codexCommandFailureIsReportedWithoutBlockingOtherAgents() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.claudeCode], home: home)
            try makeExecutable(
                name: "codex", directory: home.appendingPathComponent(".local/bin", isDirectory: true),
                contents: "#!/bin/sh\nprintf 'invalid Codex configuration' >&2\nexit 17\n")

            let outcome = try install([.claudeCode, .codex], home: home)

            #expect(outcome.failures.map(\.kind) == [.codex])
            #expect(outcome.failures.first?.message.localizedStandardContains("invalid Codex configuration") == true)
            #expect(outcome.agents.first { $0.kind == .claudeCode }?.installState == .current)
            #expect(outcome.agents.first { $0.kind == .codex }?.installState == .outdated)
        }

        @Test func codexInstallFailsWhenEnableCommandLeavesTheFeatureDisabled() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeSpacesCLIAvailable(home: home)
            try makeExecutable(
                name: "codex", directory: home.appendingPathComponent(".local/bin", isDirectory: true),
                contents: #"""
                    #!/bin/sh
                    if [ "$1 $2 $3" = "features enable hooks" ]; then
                      exit 0
                    fi
                    if [ "$1 $2" = "features list" ]; then
                      printf 'hooks stable false\n'
                      exit 0
                    fi
                    exit 64
                    """#)

            let outcome = try install([.codex], home: home)

            #expect(outcome.failures.map(\.kind) == [.codex])
            #expect(outcome.failures.first?.message.localizedStandardContains("remain disabled") == true)
            #expect(outcome.agents.first { $0.kind == .codex }?.installState == .outdated)
        }

        @Test func codexFeatureCommandTimeoutKillsTheWrapperAndItsChild() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
            try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
            let executable = try makeExecutable(
                name: "codex", directory: home.appendingPathComponent(".local/bin", isDirectory: true),
                contents: #"""
                    #!/bin/sh
                    sleep 30 &
                    child=$!
                    printf '%s\n' "$child" > "$CODEX_HOME/child.pid"
                    wait "$child"
                    """#)

            let startedAt = Date()
            #expect(throws: (any Error).self) {
                try AgentHookCodexFeatureToggle.ensureEnabled(executablePath: executable.path, codexHome: codexHome, timeoutSeconds: 2)
            }

            #expect(Date().timeIntervalSince(startedAt) < 5)
            let childPID = try #require(pid_t(read(codexHome.appendingPathComponent("child.pid")).trimmingCharacters(in: .whitespacesAndNewlines)))
            let processExitDeadline = Date().addingTimeInterval(1)
            while processExists(childPID) && Date() < processExitDeadline { usleep(10_000) }
            #expect(!processExists(childPID))
        }

        private func processExists(_ processID: pid_t) -> Bool {
            errno = 0
            return kill(processID, 0) == 0 || errno != ESRCH
        }

        // MARK: - Status

        @Test func statusReportsHooksInstalledAfterInstall() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.claudeCode, .opencode], home: home)

            let before = status(home: home)
            #expect(before.allSatisfy { $0.installState == .notInstalled })

            try install([.claudeCode, .opencode], home: home)
            let after = status(home: home)
            #expect(after.first { $0.kind == .claudeCode }?.installState == .current)
            #expect(after.first { $0.kind == .opencode }?.installState == .current)
            #expect(after.first { $0.kind == .codex }?.installState == .notInstalled)
        }

        @Test func configDirectoryPresenceDoesNotCountAsAvailable() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let configDirectory = home.appendingPathComponent(".claude", isDirectory: true)
            let fileManager = StubFileManager(existingPaths: [configDirectory.path])

            let statuses = status(home: home, fileManager: fileManager)
            #expect(statuses.first { $0.kind == .claudeCode }?.available == false)
        }

        @Test func executableInHomeLocalBinCountsAsAvailable() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.codex], home: home)

            #expect(status(home: home).first { $0.kind == .codex }?.available == true)
        }

        @Test func executableFromLoginShellPathCountsAsAvailable() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let shimDirectory = home.appendingPathComponent(".asdf/shims", isDirectory: true)
            let executablePath = shimDirectory.appendingPathComponent("codex").path
            let fileManager = StubFileManager(executablePaths: [executablePath])

            let available = AgentHookInstaller.isAvailable(
                .codex, home: home, fileManager: fileManager, environment: ["PATH": "/usr/bin:/bin"],
                shellPathDirectoryResolver: { resolverHome, _, _ in
                    #expect(resolverHome == home)
                    return [shimDirectory.path]
                })

            #expect(available)
        }

        /// Probing the login shell costs seconds, so an install and the status it returns must share one
        /// probe rather than spawning a shell per phase, and one probe must serve every agent.
        @Test func installAndTrailingStatusProbeLoginShellAtMostOnce() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let shimDirectory = home.appendingPathComponent(".asdf/shims", isDirectory: true)
            try makeExecutable(name: "codex", directory: shimDirectory, contents: Self.codexFeatureCLIScript)
            try makeSpacesCLIAvailable(home: home)
            let shell = ShellProbeSpy(directories: [shimDirectory.path])

            let outcome = try install([.codex], home: home, shell: shell)

            #expect(shell.invocationCount == 1)
            #expect(outcome.failures.isEmpty)
            #expect(outcome.agents.first { $0.kind == .codex }?.available == true)
            #expect(outcome.agents.first { $0.kind == .codex }?.installState == .awaitingTrust)
        }

        /// An undetected agent is reported as a failure and writes nothing, while its detected siblings
        /// still install: one missing CLI must not cost the whole batch.
        @Test func installReportsUnavailableAgentsWithoutWritingTheirConfig() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.claudeCode], home: home)

            let outcome = try install([.claudeCode, .codex], home: home)

            #expect(outcome.failures.map(\.kind) == [.codex])
            #expect(outcome.agents.first { $0.kind == .claudeCode }?.installState == .current)
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path))
        }

        /// Without the Spaces CLI every hook command would be unwritable, so nothing is installed at all.
        @Test func installFailsWhenTheSpacesCLIIsNotFound() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeExecutable(name: "claude", directory: home.appendingPathComponent(".local/bin", isDirectory: true))

            #expect(throws: AgentHookInstallerError.spacesCLINotFound) { try install([.claudeCode], home: home) }
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path))
        }

        /// Hook commands invoke the resolved Spaces CLI by absolute path, not a bare `spaces` that would
        /// depend on whatever PATH the agent happened to hand its hook process.
        @Test func hookCommandUsesTheResolvedSpacesPathAndMarker() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.claudeCode], home: home)

            try install([.claudeCode], home: home)

            let contents = read(home.appendingPathComponent(".claude/settings.json"))
            #expect(
                contents.contains("'\(spacesCLIPath(home: home))' agent signal done >/dev/null 2>&1 || true # \(AgentHookCommand.versionedMarker())"))
            #expect(!contents.contains("\"command\" : \"spaces agent signal"))
        }

        // MARK: - Hooks always call the installed Spaces CLI

        private func hookFiles(home: URL) -> [URL] {
            [
                home.appendingPathComponent(".claude/settings.json"), home.appendingPathComponent(".codex/hooks.json"),
                home.appendingPathComponent(".codex/config.toml"), home.appendingPathComponent(".config/opencode/plugin/spaces-agent-signal.js"),
            ]
        }

        /// A repo-built daemon prepends its own build directory to PATH, so its `spaces` is found first.
        /// Hooks written from it would send the installed app's agents to the development profile.
        @Test func installWritesTheInstalledCLIEvenWhenADevBuildCLIIsFirstOnPath() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable(CodingAgent.allCases, home: home)
            let dev = try makeDevBuildCLI(home: home)
            let installed = spacesCLIPath(home: home)

            let outcome = try install(CodingAgent.allCases, home: home, environment: dev.environment)

            #expect(outcome.failures.isEmpty)
            let claude = read(home.appendingPathComponent(".claude/settings.json"))
            let codex = read(home.appendingPathComponent(".codex/hooks.json"))
            let opencode = read(home.appendingPathComponent(".config/opencode/plugin/spaces-agent-signal.js"))
            #expect(claude.contains("'\(installed)' agent signal"))
            #expect(codex.contains("'\(installed)' agent signal"))
            #expect(opencode.contains("const SPACES_CLI = \"\(installed)\""))
            for contents in [claude, codex, opencode] { #expect(!contents.contains(dev.path)) }
            #expect(codexMCPEntry(home: home)?["command"] as? String == installed)
        }

        /// The installed macOS app's daemon finds the CLI beside its own symlink-resolved executable in the
        /// bundle, so the path it has always written is the bundle's `spaces`.
        @Test func installedAppInstallWritesTheBundledCLIPath() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.claudeCode], home: home)
            let bundleCLI = home.appendingPathComponent("Applications/Spaces.app/Contents/Resources/spaces").resolvingSymlinksInPath().path

            try install([.claudeCode], home: home)

            #expect(read(home.appendingPathComponent(".claude/settings.json")).contains("'\(bundleCLI)' agent signal"))
        }

        @Test func installRefusesWithoutAnInstalledCLIAndLeavesEveryConfigUntouched() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable(CodingAgent.allCases, home: home)
            let dev = try makeDevBuildCLI(home: home)
            try FileManager.default.removeItem(at: installedCLILink(home: home))
            let files = hookFiles(home: home)
            let userConfigs = ["{ \"model\": \"opus\" }\n", "{}\n", "[features]\nhooks = true\n", "// user plugin\n"]
            for (file, contents) in zip(files, userConfigs) {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: file, atomically: true, encoding: .utf8)
            }

            #expect(throws: AgentHookInstallerError.spacesCLINotFound) { try install(CodingAgent.allCases, home: home, environment: dev.environment) }

            #expect(files.map(read) == userConfigs)
        }

        @Test func theNotFoundMessageSaysSpacesMustBeInstalledFirst() {
            #expect(AgentHookInstallerError.spacesCLINotFound.errorDescription?.contains("Install Spaces first") == true)
        }

        /// Hooks a development build wrote name its CLI. They read out of date for every agent so Update is
        /// offered, and a reinstall moves them to the installed CLI.
        @Test func hooksPoisonedWithADevBuildCLIReadOutdatedUntilReinstalled() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable(CodingAgent.allCases, home: home)
            let dev = try makeDevBuildCLI(home: home)
            let installed = spacesCLIPath(home: home)
            try install(CodingAgent.allCases, home: home)
            try trust(.codex, home: home)
            #expect(status(home: home).allSatisfy { $0.installState == .current })

            for file in hookFiles(home: home).filter({ $0.pathExtension != "toml" }) {
                try read(file).replacingOccurrences(of: installed, with: dev.path).write(to: file, atomically: true, encoding: .utf8)
            }

            let poisoned = status(home: home, environment: dev.environment)
            #expect(poisoned.map(\.installState) == [.outdated, .outdated, .outdated])

            try install(CodingAgent.allCases, home: home, environment: dev.environment)
            try trust(.codex, home: home)
            #expect(status(home: home, environment: dev.environment).allSatisfy { $0.installState == .current })
            #expect(!read(home.appendingPathComponent(".claude/settings.json")).contains(dev.path))
            #expect(!read(home.appendingPathComponent(".config/opencode/plugin/spaces-agent-signal.js")).contains(dev.path))
        }

        /// A development daemon on a machine with the installed app reports the installed app's hooks as
        /// current, so its launch setup step has nothing to offer.
        @Test func aDevDaemonReadsTheInstalledAppsHooksAsCurrent() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable(CodingAgent.allCases, home: home)
            try install(CodingAgent.allCases, home: home)
            try trust(.codex, home: home)
            let dev = try makeDevBuildCLI(home: home)

            #expect(status(home: home, environment: dev.environment).allSatisfy { $0.installState == .current })
        }

        /// `NSHomeDirectory()` ignores an overridden `HOME`, which let an isolated-home process act on the
        /// real account's agent configs.
        @Test func defaultHomeFollowsAnOverriddenHOME() throws {
            let isolated = try makeHome()
            defer { try? FileManager.default.removeItem(at: isolated) }
            let previousHome = getenv("HOME").map { String(cString: $0) }
            setenv("HOME", isolated.path, 1)
            defer { if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") } }

            #expect(AgentHookInstaller.defaultHome().standardizedFileURL.path == isolated.standardizedFileURL.path)
        }

        @Test func hookCommandShellQuotesAPathContainingSpaces() {
            let command = AgentHookCommand.signalCommand(event: .done, spacesExecutablePath: "/Users/a b/bin/spaces")
            #expect(command == "'/Users/a b/bin/spaces' agent signal done >/dev/null 2>&1 || true # \(AgentHookCommand.versionedMarker())")
            #expect(AgentHookCommand.isSpacesOwned(command))
        }

        @Test func opencodePluginInvokesTheResolvedSpacesPath() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try makeAgentsAvailable([.opencode], home: home)

            try install([.opencode], home: home)

            let contents = read(home.appendingPathComponent(".config/opencode/plugin/spaces-agent-signal.js"))
            #expect(contents.contains("const SPACES_CLI = \"\(spacesCLIPath(home: home))\""))
            #expect(contents.contains("$`${SPACES_CLI} agent signal ${event}`"))
            #expect(!contents.contains("$`spaces agent signal"))
            #expect(!contents.contains("--workspace"))
            #expect(!contents.contains("--session"))
        }

        // MARK: - Login-shell PATH cache

        /// Drives the cache's monotonic clock without sleeping.
        private final class StubClock: @unchecked Sendable {
            private let lock = NSLock()
            private var nanoseconds: UInt64 = 0

            func advance(seconds: Double) {
                lock.lock()
                nanoseconds += UInt64(seconds * 1_000_000_000)
                lock.unlock()
            }

            var now: @Sendable () -> UInt64 {
                {
                    self.lock.lock()
                    defer { self.lock.unlock() }
                    return self.nanoseconds
                }
            }
        }

        @Test func loginShellProbeIsReusedInsideTheCacheWindow() {
            let clock = StubClock()
            let cache = AgentHookInstaller.ShellDirectoryCache(ttlSeconds: 60, now: clock.now)
            let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
            var probes = 0

            for _ in 0..<3 {
                clock.advance(seconds: 10)
                #expect(
                    cache.directories(home: home) {
                        probes += 1
                        return ["/shims"]
                    } == ["/shims"])
            }

            #expect(probes == 1)
        }

        /// `spacesd` outlives the app, so an unbounded cache would keep an agent installed through a
        /// version manager undetected across app relaunches until the daemon itself restarted.
        @Test func loginShellProbeRerunsAfterTheCacheWindowExpires() {
            let clock = StubClock()
            let cache = AgentHookInstaller.ShellDirectoryCache(ttlSeconds: 60, now: clock.now)
            let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
            var probes = 0

            #expect(
                cache.directories(home: home) {
                    probes += 1
                    return ["/old-shims"]
                } == ["/old-shims"])
            clock.advance(seconds: 61)
            // The user installed a version manager; its shim directory is on the shell's PATH now.
            #expect(
                cache.directories(home: home) {
                    probes += 1
                    return ["/old-shims", "/new-shims"]
                } == ["/old-shims", "/new-shims"])

            #expect(probes == 2)
        }

        /// A missing shell or an rc script that hangs pays the probe timeout. Caching that failure for the
        /// window is what keeps it from being paid on every status call.
        @Test func failedLoginShellProbeIsCachedForTheWindowThenRetried() {
            let clock = StubClock()
            let cache = AgentHookInstaller.ShellDirectoryCache(ttlSeconds: 60, now: clock.now)
            let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
            var probes = 0

            #expect(
                cache.directories(home: home) {
                    probes += 1
                    return []
                }.isEmpty)
            #expect(
                cache.directories(home: home) {
                    probes += 1
                    return []
                }.isEmpty)
            #expect(probes == 1)

            clock.advance(seconds: 61)
            #expect(
                cache.directories(home: home) {
                    probes += 1
                    return ["/recovered"]
                } == ["/recovered"])
            #expect(probes == 2)
        }

        @Test func loginShellProbeIsCachedPerHome() {
            let clock = StubClock()
            let cache = AgentHookInstaller.ShellDirectoryCache(ttlSeconds: 60, now: clock.now)
            var probes = 0

            _ = cache.directories(home: URL(fileURLWithPath: "/Users/one", isDirectory: true)) {
                probes += 1
                return ["/one"]
            }
            _ = cache.directories(home: URL(fileURLWithPath: "/Users/two", isDirectory: true)) {
                probes += 1
                return ["/two"]
            }

            #expect(probes == 2)
        }

        // MARK: - Login-shell PATH capture

        /// An rc chain that writes more than the 64KB pipe buffer must neither deadlock the probe (the
        /// shell blocks on write until the pipe is drained) nor truncate it: the marker line is printed
        /// last, after many read chunks. Pins the drain-while-running, read-through-to-EOF ordering.
        @Test func loginShellPATHIsCapturedAfterOutputLargerThanThePipeBuffer() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let noisyShell = try makeExecutable(
                name: "noisy-shell", directory: home,
                contents: """
                    #!/bin/sh
                    awk 'BEGIN { for (i = 0; i < 4000; i++) printf "%50s\\n", "rc-noise" }'
                    printf '\\n\(AgentHookInstaller.pathMarkerPrefix)%s\\n' "/opt/tools/bin:/usr/bin"
                    """)

            let resolved = AgentHookInstaller.resolvedLoginShellProbe(shellPath: noisyShell.path, home: home, environment: [:])?.path

            #expect(resolved == "/opt/tools/bin:/usr/bin")
        }

        @Test func loginShellPATHIsIgnoredWhenTheShellExitsNonZero() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let failingShell = try makeExecutable(
                name: "failing-shell", directory: home,
                contents: """
                    #!/bin/sh
                    printf '\\n\(AgentHookInstaller.pathMarkerPrefix)%s\\n' "/opt/tools/bin"
                    exit 3
                    """)

            #expect(AgentHookInstaller.resolvedLoginShellProbe(shellPath: failingShell.path, home: home, environment: [:]) == nil)
        }

        @Test func loginShellPATHTimeoutKillsTheShellAndItsChild() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let hangingShell = try makeExecutable(
                name: "hanging-shell", directory: home,
                contents: #"""
                    #!/bin/sh
                    sh -c 'trap "" HUP TERM; sleep 30' &
                    child=$!
                    printf '%s\n' "$child" > "$HOME/shell-child.pid"
                    wait "$child"
                    """#)

            let startedAt = Date()
            #expect(AgentHookInstaller.resolvedLoginShellProbe(shellPath: hangingShell.path, home: home, environment: [:], timeoutSeconds: 2) == nil)

            #expect(Date().timeIntervalSince(startedAt) < 6)
            let childPID = try #require(pid_t(read(home.appendingPathComponent("shell-child.pid")).trimmingCharacters(in: .whitespacesAndNewlines)))
            defer { if processExists(childPID) { kill(childPID, SIGKILL) } }
            let processExitDeadline = Date().addingTimeInterval(1)
            while processExists(childPID) && Date() < processExitDeadline { usleep(10_000) }
            #expect(!processExists(childPID))
        }

        // MARK: - Ephemeral per-shell PATH directories (fnm multishell)

        /// A fake login shell that emulates fnm's `zshexit` hook: it puts a per-invocation directory
        /// (named by its own PID, mirroring fnm's `fnm_multishells/<pid>_<ts>`) with a `bin` symlink into
        /// `realBinDirectory` first on PATH, runs the probe command it was given, and, only when
        /// `deleteOnExit` is set, deletes that per-invocation directory as its last act, the way a user's
        /// `zshexit` hook does to keep fnm from leaking one such directory per shell. `trailingPathDirectory`,
        /// when given, sits on PATH right after the per-invocation directory: it lets a test put another
        /// installation of the same executable later on PATH, to check precedence against that directory's
        /// canonical fallback rather than against the per-invocation directory itself.
        private func makeEphemeralMultishellLoginShell(
            home: URL, multishellParent: URL, realBinDirectory: URL, deleteOnExit: Bool, trailingPathDirectory: URL? = nil
        ) throws -> URL {
            try FileManager.default.createDirectory(at: multishellParent, withIntermediateDirectories: true)
            let cleanup = deleteOnExit ? "trap 'rm -rf \"$link\"' EXIT\n" : ""
            let trailingSegment = trailingPathDirectory.map { "\($0.path):" } ?? ""
            return try makeExecutable(
                name: "fake-login-shell", directory: home,
                contents: """
                    #!/bin/sh
                    while [ "$1" != "-c" ]; do shift; done
                    shift
                    cmd="$1"
                    link="\(multishellParent.path)/$$"
                    mkdir -p "$link"
                    ln -s "\(realBinDirectory.path)" "$link/bin"
                    export PATH="$link/bin:\(trailingSegment)$PATH"
                    \(cleanup)eval "$cmd"
                    """)
        }

        /// Reproduces the real failure: fnm puts `codex` on PATH through a per-shell symlink directory,
        /// and the user's shell deletes that directory when it exits. By the time the resolver checks the
        /// directory the login shell reported, the shell (and the probe's own `/bin/sh` child) has already
        /// exited and the directory is gone, so `codex` reads "Not detected" even though it is installed.
        /// This fails on the pre-fix resolver, which only ever tries the directories the shell reported
        /// (all deleted by the time it looks), and passes once the probe also reports each directory's
        /// canonical form, captured while the shell was still alive.
        @Test func executableInADeletedPerShellSymlinkDirectoryStillResolvesThroughItsCanonicalPath() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let realBinDirectory = home.appendingPathComponent("real-agent-bin", isDirectory: true)
            try makeExecutable(name: "codex", directory: realBinDirectory)
            let fakeLoginShell = try makeEphemeralMultishellLoginShell(
                home: home, multishellParent: home.appendingPathComponent("multishell", isDirectory: true), realBinDirectory: realBinDirectory,
                deleteOnExit: true)

            let available = AgentHookInstaller.isAvailable(
                .codex, home: home, fileManager: HomeScopedFileManager(home: home),
                environment: ["PATH": "/usr/bin:/bin", "SHELL": fakeLoginShell.path],
                shellPathDirectoryResolver: AgentHookInstaller.loginShellPathDirectories)

            #expect(available)
        }

        /// The deleted per-shell directory's canonical fallback must sit ahead of a later, unrelated PATH
        /// directory that happens to hold an executable of the same name, not after the whole PATH has
        /// been exhausted: PATH order is how a user chooses which of several installs wins, and an fnm-
        /// selected `codex` silently losing to a later `codex` on PATH defeats that choice. The later
        /// directory's `codex` always fails, so the install only succeeds when the canonical fallback (the
        /// working script under `realBinDirectory`) is the one actually picked.
        @Test func canonicalFallbackForADeletedPerShellDirectoryOutranksALaterPathDirectoryWithTheSameExecutableName() throws {
            let home = try makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let realBinDirectory = home.appendingPathComponent("real-agent-bin", isDirectory: true)
            try makeExecutable(name: "codex", directory: realBinDirectory, contents: Self.codexFeatureCLIScript)
            try makeSpacesCLIAvailable(home: home)
            let laterDirectory = home.appendingPathComponent("later-bin", isDirectory: true)
            try makeExecutable(name: "codex", directory: laterDirectory, contents: "#!/bin/sh\nexit 1\n")
            let multishellParent = home.appendingPathComponent("multishell", isDirectory: true)
            let fakeLoginShell = try makeEphemeralMultishellLoginShell(
                home: home, multishellParent: multishellParent, realBinDirectory: realBinDirectory, deleteOnExit: true,
                trailingPathDirectory: laterDirectory)

            let outcome = try AgentHookInstaller.install(
                [.codex], home: home, fileManager: HomeScopedFileManager(home: home),
                environment: ["PATH": "/usr/bin:/bin", "SHELL": fakeLoginShell.path],
                shellPathDirectoryResolver: AgentHookInstaller.loginShellPathDirectories, codexAppServer: FakeCodexAppServer().launcher)

            #expect(outcome.failures.isEmpty)
            #expect(outcome.agents.first { $0.kind == .codex }?.installState == .awaitingTrust)
        }

    }
#endif
