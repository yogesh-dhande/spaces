import Foundation
import Testing

@testable import spacesterminalcore

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

@Suite struct AgentHookInstallerTests {
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
        _ kinds: [SupportedCodingAgentHook], home: URL, fileManager: FileManager? = nil, shell: ShellProbeSpy = ShellProbeSpy()
    ) throws -> AgentHookInstallOutcome {
        try AgentHookInstaller.install(
            kinds, home: home, fileManager: fileManager ?? HomeScopedFileManager(home: home), environment: environment,
            shellPathDirectoryResolver: shell.resolver)
    }

    private func status(home: URL, fileManager: FileManager? = nil, shell: ShellProbeSpy = ShellProbeSpy()) -> [AgentHookStatus] {
        AgentHookInstaller.status(
            home: home, fileManager: fileManager ?? HomeScopedFileManager(home: home), environment: environment,
            shellPathDirectoryResolver: shell.resolver)
    }

    /// Availability probing scans real system directories (`/usr/local/bin`, `/opt/homebrew/bin`, …) in
    /// addition to the home under test. A `spaces` or agent CLI installed on the machine running these
    /// tests would otherwise satisfy the probe, so executables outside the temporary home are hidden.
    /// Only the probe is scoped; reads and writes pass straight through.
    private final class HomeScopedFileManager: FileManager {
        private let homePath: String

        init(home: URL) {
            self.homePath = home.path
            super.init()
        }

        override func isExecutableFile(atPath path: String) -> Bool { path.hasPrefix(homePath + "/") && super.isExecutableFile(atPath: path) }
    }

    /// Every install resolves the Spaces CLI to embed in the hook commands, so a home that has agents
    /// but no `spaces` cannot install anything. Tests that install put both in `~/.local/bin`.
    private func makeAgentsAvailable(_ kinds: [SupportedCodingAgentHook], home: URL) throws {
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
        printf 'unexpected codex arguments\n' >&2
        exit 64
        """#

    @discardableResult private func makeSpacesCLIAvailable(home: URL) throws -> URL {
        try makeExecutable(name: AgentHookCommand.spacesExecutableName, directory: home.appendingPathComponent(".local/bin", isDirectory: true))
    }

    private func spacesCLIPath(home: URL) -> String { home.appendingPathComponent(".local/bin/\(AgentHookCommand.spacesExecutableName)").path }

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
        try makeAgentsAvailable(SupportedCodingAgentHook.allCases, home: home)

        try install(SupportedCodingAgentHook.allCases, home: home)
        let files = [
            home.appendingPathComponent(".claude/settings.json"), home.appendingPathComponent(".codex/hooks.json"),
            home.appendingPathComponent(".codex/config.toml"), home.appendingPathComponent(".config/opencode/plugin/spaces-agent-signal.js"),
        ]
        let firstPass = files.map(read)

        let replayOutcome = try install(SupportedCodingAgentHook.allCases, home: home)
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
        #expect(markerCount == SupportedCodingAgentHook.claudeCode.jsonEventBindings.count)
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
        #expect(outcome.agents.first { $0.kind == .codex }?.installState == .current)
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
        // `spaces` lives there too, so resolving it, resolving codex, and the trailing status all ride
        // the same probe rather than spawning a shell each.
        try makeExecutable(name: AgentHookCommand.spacesExecutableName, directory: shimDirectory)
        let shell = ShellProbeSpy(directories: [shimDirectory.path])

        let outcome = try install([.codex], home: home, shell: shell)

        #expect(shell.invocationCount == 1)
        #expect(outcome.failures.isEmpty)
        #expect(outcome.agents.first { $0.kind == .codex }?.available == true)
        #expect(outcome.agents.first { $0.kind == .codex }?.installState == .current)
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
        #expect(contents.contains("'\(spacesCLIPath(home: home))' agent signal done >/dev/null 2>&1 || true # \(AgentHookCommand.versionedMarker())"))
        #expect(!contents.contains("\"command\" : \"spaces agent signal"))
    }

    @Test func installedLinuxReleasePathUsesTheStableSpacesCLI() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let releaseBin = home.appendingPathComponent(".spaces/daemon/releases/1.2.3/bin", isDirectory: true)
        try makeExecutable(name: "spaces", directory: releaseBin)
        try makeExecutable(name: "claude", directory: releaseBin)
        let stableCLI = try makeExecutable(name: "spaces", directory: home.appendingPathComponent(".spaces/bin", isDirectory: true))

        let outcome = try AgentHookInstaller.install(
            [.claudeCode], home: home, fileManager: HomeScopedFileManager(home: home), environment: ["PATH": releaseBin.path],
            shellPathDirectoryResolver: ShellProbeSpy().resolver)

        #expect(outcome.failures.isEmpty)
        #expect(read(home.appendingPathComponent(".claude/settings.json")).contains("'\(stableCLI.path)' agent signal"))
    }

    @Test func installedLinuxReleasePathFailsWhenTheStableSpacesCLIIsMissing() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let releaseBin = home.appendingPathComponent(".spaces/daemon/releases/1.2.3/bin", isDirectory: true)
        try makeExecutable(name: "spaces", directory: releaseBin)
        try makeExecutable(name: "claude", directory: releaseBin)

        #expect(throws: AgentHookInstallerError.spacesCLINotFound) {
            try AgentHookInstaller.install(
                [.claudeCode], home: home, fileManager: HomeScopedFileManager(home: home), environment: ["PATH": releaseBin.path],
                shellPathDirectoryResolver: ShellProbeSpy().resolver)
        }
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path))
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

        let resolved = AgentHookInstaller.resolvedLoginShellPATH(shellPath: noisyShell.path, home: home, environment: [:])

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

        #expect(AgentHookInstaller.resolvedLoginShellPATH(shellPath: failingShell.path, home: home, environment: [:]) == nil)
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
        #expect(AgentHookInstaller.resolvedLoginShellPATH(shellPath: hangingShell.path, home: home, environment: [:], timeoutSeconds: 2) == nil)

        #expect(Date().timeIntervalSince(startedAt) < 6)
        let childPID = try #require(pid_t(read(home.appendingPathComponent("shell-child.pid")).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { if processExists(childPID) { kill(childPID, SIGKILL) } }
        let processExitDeadline = Date().addingTimeInterval(1)
        while processExists(childPID) && Date() < processExitDeadline { usleep(10_000) }
        #expect(!processExists(childPID))
    }
}
