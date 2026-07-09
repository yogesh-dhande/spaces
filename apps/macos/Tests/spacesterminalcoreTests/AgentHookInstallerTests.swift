import Foundation
import Testing

@testable import spacesterminalcore

@Suite struct AgentHookInstallerTests {
    /// Availability probing reads `PATH` and, on a miss, the user's login shell. Tests pin both: an
    /// empty `PATH` (the common install directories still apply) and a stub shell probe, so no test
    /// depends on the developer's environment or spawns a real interactive shell.
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
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    @discardableResult
    private func install(
        _ kinds: [SupportedCodingAgentHook], home: URL, fileManager: FileManager = .default, shell: ShellProbeSpy = ShellProbeSpy()
    ) throws -> [AgentHookStatus] {
        try AgentHookInstaller.install(
            kinds, home: home, fileManager: fileManager, environment: environment, shellPathDirectoryResolver: shell.resolver)
    }

    private func status(home: URL, fileManager: FileManager = .default, shell: ShellProbeSpy = ShellProbeSpy()) -> [AgentHookStatus] {
        AgentHookInstaller.status(home: home, fileManager: fileManager, environment: environment, shellPathDirectoryResolver: shell.resolver)
    }

    private func makeAgentsAvailable(_ kinds: [SupportedCodingAgentHook], home: URL) throws {
        for name in Set(kinds.flatMap(\.executableNames)) {
            try makeExecutable(name: name, directory: home.appendingPathComponent(".local/bin", isDirectory: true))
        }
    }

    @discardableResult
    private func makeExecutable(name: String, directory: URL, contents: String = "#!/bin/sh\n") throws -> URL {
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
            home.appendingPathComponent(".claude/settings.json"),
            home.appendingPathComponent(".codex/hooks.json"),
            home.appendingPathComponent(".codex/config.toml"),
            home.appendingPathComponent(".config/opencode/plugin/spaces-agent-signal.js"),
        ]
        let firstPass = files.map(read)

        try install(SupportedCodingAgentHook.allCases, home: home)
        let secondPass = files.map(read)

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

    @Test func reinstallPreservesUserHookEntriesInsideMixedHookGroup() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeAgentsAvailable([.claudeCode], home: home)
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let userCommand = "/opt/user/session-start"
        let existing = """
            {
              "hooks": {
                "SessionStart": [
                  {
                    "matcher": "",
                    "hooks": [
                      { "type": "command", "command": "\(AgentHookCommand.signalCommand(event: .initialize))" },
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
        let commands = groups.flatMap { group in
            ((group["hooks"] as? [[String: Any]]) ?? []).compactMap { $0["command"] as? String }
        }

        #expect(commands.contains(userCommand))
        #expect(commands.filter(AgentHookCommand.isSpacesOwned).count == 1)
    }

    /// Agent configs are commonly symlinked into a dotfiles repo. An atomic write to the link path
    /// would replace the link with a regular file and silently detach the user's managed config.
    @Test func installWritesThroughSymlinkedConfigsAndKeepsTheLinks() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeAgentsAvailable([.claudeCode, .codex], home: home)

        let dotfiles = home.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let managedSettings = dotfiles.appendingPathComponent("settings.json")
        try "{ \"model\": \"opus\" }".write(to: managedSettings, atomically: true, encoding: .utf8)
        let managedCodexConfig = dotfiles.appendingPathComponent("config.toml")
        try "model = \"gpt-5\"\n".write(to: managedCodexConfig, atomically: true, encoding: .utf8)

        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: managedSettings)
        let codexConfig = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A relative link destination, as `stow` and friends create.
        try FileManager.default.createSymbolicLink(atPath: codexConfig.path, withDestinationPath: "../dotfiles/config.toml")

        try install([.claudeCode, .codex], home: home)

        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: settings.path)) == managedSettings.path)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: codexConfig.path)) == "../dotfiles/config.toml")
        // The hooks landed in the dotfiles repo, alongside the settings the user already had there.
        #expect(read(managedSettings).contains(AgentHookCommand.marker))
        #expect(read(managedSettings).contains("opus"))
        #expect(read(managedCodexConfig).contains("hooks = true"))
        #expect(read(managedCodexConfig).contains("gpt-5"))
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

        #expect(throws: (any Error).self) {
            try install([.claudeCode], home: home)
        }
        #expect(read(settings) == garbage)
    }

    // MARK: - Codex feature toggle

    @Test func codexEnablesFeaturesHooksPreservingConfig() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeAgentsAvailable([.codex], home: home)
        let config = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "model = \"gpt-5\"\n\n[features]\njs_repl = false\n".write(to: config, atomically: true, encoding: .utf8)

        try install([.codex], home: home)
        let contents = read(config)
        #expect(contents.contains("model = \"gpt-5\""))
        #expect(contents.contains("js_repl = false"))
        #expect(AgentHookCodexFeatureToggle.isEnabled(fileURL: config))
    }

    @Test func codexFeatureToggleAppendsSectionWhenAbsent() throws {
        #expect(try AgentHookCodexFeatureToggle.updatedContents("model = \"gpt-5\"\n")?.contains("[features]") == true)
        // Already-enabled input needs no change.
        #expect(try AgentHookCodexFeatureToggle.updatedContents("[features]\nhooks = true\n") == nil)
    }

    @Test func codexFeatureToggleLeavesEnabledInlineFeaturesTableUntouched() throws {
        let contents = "model = \"gpt-5\"\nfeatures = { hooks = true, js_repl = false }\n"

        #expect(try AgentHookCodexFeatureToggle.updatedContents(contents) == nil)
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: config, atomically: true, encoding: .utf8)
        #expect(AgentHookCodexFeatureToggle.isEnabled(fileURL: config))
    }

    @Test func codexFeatureToggleLeavesEnabledDottedFeaturesHookUntouched() throws {
        let contents = "model = \"gpt-5\"\nfeatures.hooks = true\n"

        #expect(try AgentHookCodexFeatureToggle.updatedContents(contents) == nil)
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: config, atomically: true, encoding: .utf8)
        #expect(AgentHookCodexFeatureToggle.isEnabled(fileURL: config))
    }

    @Test func codexFeatureToggleUpdatesDottedFeaturesHookInPlace() throws {
        let updated = try AgentHookCodexFeatureToggle.updatedContents("model = \"gpt-5\"\nfeatures.hooks = false # disabled\n")

        #expect(updated?.contains("features.hooks = true # disabled") == true)
        #expect(updated?.contains("[features]") == false)
    }

    @Test func codexFeatureToggleAddsDottedHookWhenOtherDottedFeaturesExist() throws {
        let updated = try AgentHookCodexFeatureToggle.updatedContents("model = \"gpt-5\"\nfeatures.experimental = true\n")

        #expect(updated?.contains("features.experimental = true\nfeatures.hooks = true") == true)
        #expect(updated?.contains("[features]") == false)
    }

    @Test func codexFeatureToggleUpdatesInlineFeaturesTableInPlace() throws {
        let updated = try AgentHookCodexFeatureToggle.updatedContents("model = \"gpt-5\"\nfeatures = { js_repl = false }\n")

        #expect(updated?.contains("features = { hooks = true, js_repl = false }") == true)
        #expect(updated?.contains("[features]") == false)
    }

    @Test func codexFeatureToggleDoesNotTreatNestedInlineFeaturesAsGlobal() throws {
        let updated = try AgentHookCodexFeatureToggle.updatedContents("[agents]\nfeatures = { hooks = true }\n")

        #expect(updated?.contains("[agents]\nfeatures = { hooks = true }") == true)
        #expect(updated?.contains("[features]\nhooks = true") == true)
    }

    @Test func codexFeatureToggleFlipsFalseToTrueWithoutTouchingOtherSections() throws {
        let updated = try AgentHookCodexFeatureToggle.updatedContents("[features]\nhooks = false\njs_repl = true\n\n[agents]\nmax_depth = 2\n")
        #expect(updated?.contains("hooks = true") == true)
        #expect(updated?.contains("hooks = false") == false)
        #expect(updated?.contains("js_repl = true") == true)
        #expect(updated?.contains("[agents]") == true)
    }

    @Test func codexFeatureToggleRecognizesCommentedSectionHeaders() throws {
        let updated = try AgentHookCodexFeatureToggle.updatedContents("[features] # flags\njs_repl = true\n\n[agents] # defaults\nhooks = false\n")

        #expect(updated?.hasPrefix("[features] # flags\nhooks = true\njs_repl = true") == true)
        #expect(updated?.contains("[agents] # defaults\nhooks = false") == true)
    }

    @Test func codexFeatureToggleLeavesEnabledCommentedHeaderUntouched() throws {
        let contents = "[features] # flags\nhooks = true # enabled\n"

        #expect(try AgentHookCodexFeatureToggle.updatedContents(contents) == nil)
    }

    // A `[features]` header the matcher fails to recognize is not a missed edit: the toggle falls
    // through to appending a second `[features]` table, and the duplicate table definition makes Codex
    // fail to parse `config.toml` at all. Each spelling below must be edited in place.

    @Test func codexFeatureToggleEditsSpacedSectionHeaderInPlace() throws {
        let updated = try AgentHookCodexFeatureToggle.updatedContents("[ features ]\njs_repl = false\n")

        #expect(updated?.hasPrefix("[ features ]\nhooks = true\njs_repl = false") == true)
        #expect(updated?.contains("[features]") == false)  // no duplicate table appended
    }

    @Test func codexFeatureToggleEditsQuotedSectionHeaderInPlace() throws {
        let updated = try AgentHookCodexFeatureToggle.updatedContents("[\"features\"]\njs_repl = false\n")

        #expect(updated?.hasPrefix("[\"features\"]\nhooks = true\njs_repl = false") == true)
        #expect(updated?.contains("[features]") == false)
    }

    @Test func codexFeatureToggleLeavesEnabledSpacedSectionHeaderUntouched() throws {
        #expect(try AgentHookCodexFeatureToggle.updatedContents("[ features ]\nhooks = true\n") == nil)
    }

    @Test func codexFeatureToggleUpdatesQuotedHooksKeyInPlace() throws {
        let updated = try AgentHookCodexFeatureToggle.updatedContents("[features]\n\"hooks\" = false\n")

        #expect(updated?.contains("\"hooks\" = true") == true)
        #expect(updated?.contains("hooks = true\n\"hooks\"") == false)  // not inserted alongside
    }

    @Test func codexFeatureToggleUpdatesQuotedDottedFeaturesHookInPlace() throws {
        let updated = try AgentHookCodexFeatureToggle.updatedContents("\"features\".hooks = false\n")

        #expect(updated?.contains("\"features\".hooks = true") == true)
        #expect(updated?.contains("[features]") == false)
    }

    @Test func codexFeatureTogglePreservesIndentationAndCommentInSectionEdit() throws {
        let updated = try AgentHookCodexFeatureToggle.updatedContents("[features]\n  hooks = false # keep this note\n")

        #expect(updated?.contains("  hooks = true # keep this note") == true)
    }

    @Test func codexFeatureToggleTreatsFeaturesSubTableAsSeparateTable() throws {
        // `[features.sub]` does not define `features.hooks`, so a `[features]` table is still required.
        let updated = try AgentHookCodexFeatureToggle.updatedContents("[features.sub]\nx = 1\n")

        #expect(updated?.hasSuffix("[features]\nhooks = true\n") == true)
    }

    /// `features` already defined in a shape the line editor cannot extend. Appending a `[features]`
    /// table beside any of these is a duplicate key or a table-type conflict, which costs the user
    /// their whole Codex config — so the install must fail loudly instead.
    @Test func codexFeatureToggleRefusesToAppendBesideAnUneditableFeaturesDefinition() throws {
        let conflicts = [
            "[features.hooks]\nenabled = true\n",  // `hooks` is a table; `hooks = true` would collide
            "[[features]]\nname = \"a\"\n",  // `features` is an array of tables
            "model = \"gpt-5\"\nfeatures = 3\n",  // `features` is a scalar
            "features = [\"a\", \"b\"]\n",  // `features` is an array
        ]
        for contents in conflicts {
            #expect(throws: (any Error).self) { try AgentHookCodexFeatureToggle.updatedContents(contents) }
        }
    }

    @Test func codexInstallLeavesAConflictingConfigUntouched() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeAgentsAvailable([.codex], home: home)
        let config = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "[[features]]\nname = \"a\"\n"
        try original.write(to: config, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) { try install([.codex], home: home) }
        #expect(read(config) == original)
    }

    @Test func codexFeatureToggleDoesNotOverwriteUnreadableConfig() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data([0xFF, 0xFE, 0xFD])
        try original.write(to: config)

        #expect(throws: (any Error).self) {
            try AgentHookCodexFeatureToggle.ensureEnabled(fileURL: config)
        }
        #expect((try? Data(contentsOf: config)) == original)
    }

    // MARK: - Status

    @Test func statusReportsHooksInstalledAfterInstall() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeAgentsAvailable([.claudeCode, .opencode], home: home)

        let before = status(home: home)
        #expect(before.allSatisfy { !$0.hooksInstalled })

        try install([.claudeCode, .opencode], home: home)
        let after = status(home: home)
        #expect(after.first { $0.kind == .claudeCode }?.hooksInstalled == true)
        #expect(after.first { $0.kind == .opencode }?.hooksInstalled == true)
        #expect(after.first { $0.kind == .codex }?.hooksInstalled == false)
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
        try makeExecutable(name: "codex", directory: shimDirectory)
        let shell = ShellProbeSpy(directories: [shimDirectory.path])

        let statuses = try install([.codex], home: home, shell: shell)

        #expect(shell.invocationCount == 1)
        #expect(statuses.first { $0.kind == .codex }?.available == true)
        #expect(statuses.first { $0.kind == .codex }?.hooksInstalled == true)
    }

    @Test func installRejectsUnavailableAgentsBeforeWritingConfig() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fileManager = StubFileManager()

        #expect(throws: AgentHookInstallerError.unavailableAgents([.codex])) {
            try install([.codex], home: home, fileManager: fileManager)
        }
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path))
    }

    @Test func hookCommandUsesPathResolvedSpacesAndMarker() {
        let command = AgentHookCommand.signalCommand(event: .done)
        #expect(command == "spaces agent signal done >/dev/null 2>&1 || true # \(AgentHookCommand.marker)")
        #expect(AgentHookCommand.isSpacesOwned(command))
    }

    @Test func opencodePluginUsesPathResolvedSpacesSignal() {
        let contents = AgentHookOpencodePluginWriter.pluginContents()

        #expect(contents.contains("spaces agent signal ${event}"))
        #expect(!contents.contains("--workspace"))
        #expect(!contents.contains("--session"))
        #expect(!contents.contains("SPACES_CLI"))
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
            #expect(cache.directories(home: home) { probes += 1; return ["/shims"] } == ["/shims"])
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

        #expect(cache.directories(home: home) { probes += 1; return ["/old-shims"] } == ["/old-shims"])
        clock.advance(seconds: 61)
        // The user installed a version manager; its shim directory is on the shell's PATH now.
        #expect(cache.directories(home: home) { probes += 1; return ["/old-shims", "/new-shims"] } == ["/old-shims", "/new-shims"])

        #expect(probes == 2)
    }

    /// A missing shell or an rc script that hangs pays the probe timeout. Caching that failure for the
    /// window is what keeps it from being paid on every status call.
    @Test func failedLoginShellProbeIsCachedForTheWindowThenRetried() {
        let clock = StubClock()
        let cache = AgentHookInstaller.ShellDirectoryCache(ttlSeconds: 60, now: clock.now)
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        var probes = 0

        #expect(cache.directories(home: home) { probes += 1; return [] }.isEmpty)
        #expect(cache.directories(home: home) { probes += 1; return [] }.isEmpty)
        #expect(probes == 1)

        clock.advance(seconds: 61)
        #expect(cache.directories(home: home) { probes += 1; return ["/recovered"] } == ["/recovered"])
        #expect(probes == 2)
    }

    @Test func loginShellProbeIsCachedPerHome() {
        let clock = StubClock()
        let cache = AgentHookInstaller.ShellDirectoryCache(ttlSeconds: 60, now: clock.now)
        var probes = 0

        _ = cache.directories(home: URL(fileURLWithPath: "/Users/one", isDirectory: true)) { probes += 1; return ["/one"] }
        _ = cache.directories(home: URL(fileURLWithPath: "/Users/two", isDirectory: true)) { probes += 1; return ["/two"] }

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
}
