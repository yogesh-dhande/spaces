import Foundation
import Testing

@testable import spacesterminalcore

@Suite struct AgentHookInstallerTests {
    private let cliPath = "/Users/test/.spaces/bin/spaces"

    private func makeHome() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    private func makeAgentsAvailable(_ kinds: [SupportedCodingAgentHook], home: URL) throws {
        for name in Set(kinds.flatMap(\.executableNames)) {
            try makeExecutable(name: name, home: home)
        }
    }

    private func makeExecutable(name: String, home: URL) throws {
        let file = home.appendingPathComponent(".local/bin/\(name)")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
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

        try AgentHookInstaller.install(SupportedCodingAgentHook.allCases, home: home, cliPath: cliPath)
        let files = [
            home.appendingPathComponent(".claude/settings.json"),
            home.appendingPathComponent(".codex/hooks.json"),
            home.appendingPathComponent(".codex/config.toml"),
            home.appendingPathComponent(".config/opencode/plugin/spaces-agent-signal.js"),
        ]
        let firstPass = files.map(read)

        try AgentHookInstaller.install(SupportedCodingAgentHook.allCases, home: home, cliPath: cliPath)
        let secondPass = files.map(read)

        #expect(firstPass == secondPass)
        for contents in firstPass { #expect(!contents.isEmpty) }
    }

    @Test func replayDoesNotDuplicateHookEntries() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeAgentsAvailable([.claudeCode], home: home)

        for _ in 0..<3 { try AgentHookInstaller.install([.claudeCode], home: home, cliPath: cliPath) }

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

        try AgentHookInstaller.install([.claudeCode], home: home, cliPath: cliPath)
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

        try AgentHookInstaller.install([.claudeCode], home: home, cliPath: cliPath)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        let hooks = object["hooks"] as! [String: Any]
        let groups = hooks["SessionStart"] as! [[String: Any]]
        let commands = groups.flatMap { group in
            ((group["hooks"] as? [[String: Any]]) ?? []).compactMap { $0["command"] as? String }
        }

        #expect(commands.contains(userCommand))
        #expect(commands.filter(AgentHookCommand.isSpacesOwned).count == 1)
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
            try AgentHookInstaller.install([.claudeCode], home: home, cliPath: cliPath)
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

        try AgentHookInstaller.install([.codex], home: home, cliPath: cliPath)
        let contents = read(config)
        #expect(contents.contains("model = \"gpt-5\""))
        #expect(contents.contains("js_repl = false"))
        #expect(AgentHookCodexFeatureToggle.isEnabled(fileURL: config))
    }

    @Test func codexFeatureToggleAppendsSectionWhenAbsent() throws {
        #expect(AgentHookCodexFeatureToggle.updatedContents("model = \"gpt-5\"\n")?.contains("[features]") == true)
        // Already-enabled input needs no change.
        #expect(AgentHookCodexFeatureToggle.updatedContents("[features]\nhooks = true\n") == nil)
    }

    @Test func codexFeatureToggleLeavesEnabledInlineFeaturesTableUntouched() throws {
        let contents = "model = \"gpt-5\"\nfeatures = { hooks = true, js_repl = false }\n"

        #expect(AgentHookCodexFeatureToggle.updatedContents(contents) == nil)
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: config, atomically: true, encoding: .utf8)
        #expect(AgentHookCodexFeatureToggle.isEnabled(fileURL: config))
    }

    @Test func codexFeatureToggleUpdatesInlineFeaturesTableInPlace() {
        let updated = AgentHookCodexFeatureToggle.updatedContents("model = \"gpt-5\"\nfeatures = { js_repl = false }\n")

        #expect(updated?.contains("features = { hooks = true, js_repl = false }") == true)
        #expect(updated?.contains("[features]") == false)
    }

    @Test func codexFeatureToggleDoesNotTreatNestedInlineFeaturesAsGlobal() {
        let updated = AgentHookCodexFeatureToggle.updatedContents("[agents]\nfeatures = { hooks = true }\n")

        #expect(updated?.contains("[agents]\nfeatures = { hooks = true }") == true)
        #expect(updated?.contains("[features]\nhooks = true") == true)
    }

    @Test func codexFeatureToggleFlipsFalseToTrueWithoutTouchingOtherSections() throws {
        let updated = AgentHookCodexFeatureToggle.updatedContents("[features]\nhooks = false\njs_repl = true\n\n[agents]\nmax_depth = 2\n")
        #expect(updated?.contains("hooks = true") == true)
        #expect(updated?.contains("hooks = false") == false)
        #expect(updated?.contains("js_repl = true") == true)
        #expect(updated?.contains("[agents]") == true)
    }

    @Test func codexFeatureToggleRecognizesCommentedSectionHeaders() throws {
        let updated = AgentHookCodexFeatureToggle.updatedContents("[features] # flags\njs_repl = true\n\n[agents] # defaults\nhooks = false\n")

        #expect(updated?.hasPrefix("[features] # flags\nhooks = true\njs_repl = true") == true)
        #expect(updated?.contains("[agents] # defaults\nhooks = false") == true)
    }

    @Test func codexFeatureToggleLeavesEnabledCommentedHeaderUntouched() throws {
        let contents = "[features] # flags\nhooks = true # enabled\n"

        #expect(AgentHookCodexFeatureToggle.updatedContents(contents) == nil)
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

        let before = AgentHookInstaller.status(home: home)
        #expect(before.allSatisfy { !$0.hooksInstalled })

        try AgentHookInstaller.install([.claudeCode, .opencode], home: home, cliPath: cliPath)
        let after = AgentHookInstaller.status(home: home)
        #expect(after.first { $0.kind == .claudeCode }?.hooksInstalled == true)
        #expect(after.first { $0.kind == .opencode }?.hooksInstalled == true)
        #expect(after.first { $0.kind == .codex }?.hooksInstalled == false)
    }

    @Test func configDirectoryPresenceDoesNotCountAsAvailable() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let configDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        let fileManager = StubFileManager(existingPaths: [configDirectory.path])

        let status = AgentHookInstaller.status(home: home, fileManager: fileManager)
        #expect(status.first { $0.kind == .claudeCode }?.available == false)
    }

    @Test func executableInHomeLocalBinCountsAsAvailable() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeAgentsAvailable([.codex], home: home)

        let status = AgentHookInstaller.status(home: home)
        #expect(status.first { $0.kind == .codex }?.available == true)
    }

    @Test func installRejectsUnavailableAgentsBeforeWritingConfig() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fileManager = StubFileManager()

        #expect(throws: AgentHookInstallerError.unavailableAgents([.codex])) {
            try AgentHookInstaller.install([.codex], home: home, cliPath: cliPath, fileManager: fileManager)
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
}
