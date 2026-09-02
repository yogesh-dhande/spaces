import Foundation
import Testing

@testable import spacesterminalcore

/// Hooks carry the `AgentHookCommand.hookVersion` that wrote them, so a Spaces release that changes
/// the hook shape can tell an older build's hooks apart from its own and offer to update them.
///
/// The invariant these tests protect: ownership (`isSpacesOwned`) is version-*less* and drives what a
/// reinstall strips, while currency (`isCurrent`) is version-aware and drives only what status reports.
/// Confusing the two either leaves stale hooks behind or duplicates them on every reinstall.
// Serialized: several tests spawn a real stub `codex` child process with a fixed deadline; running
// them concurrently alongside AgentHookInstallerTests' spawners starves those deadlines under load
// (parallel: 15 failures across the two suites; serialized: 47/47 in 5.2s). `.serialized` only orders
// tests within this suite.
@Suite(.serialized) struct AgentHookVersionTests {
    private let bindings: [AgentHookJSONWriter.EventBinding] = [
        .init(eventName: "SessionStart", event: .initialize), .init(eventName: "Stop", event: .done),
    ]

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agent-hook-version-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeCodexFeatureListExecutable(in directory: URL, enabled: Bool) throws -> String {
        let executable = directory.appendingPathComponent("codex")
        try "#!/bin/sh\nprintf 'hooks stable \(enabled)\\n'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable.path
    }

    /// A hook command as an older Spaces build would have written it.
    private func command(event: AgentHookLifecycleEvent, version: Int) -> String {
        "'/usr/local/bin/spaces' agent signal \(event.rawValue) >/dev/null 2>&1 || true # \(AgentHookCommand.versionedMarker(version))"
    }

    private func writeHooks(_ hooks: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: ["hooks": hooks])
        try data.write(to: url)
    }

    private func group(_ command: String) -> [String: Any] { ["matcher": "", "hooks": [["type": "command", "command": command]]] }

    private func readCommands(_ url: URL, eventName: String) throws -> [String] {
        let data = try Data(contentsOf: url)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])
        let groups = (hooks[eventName] as? [[String: Any]]) ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { $0["command"] as? String }
    }

    // MARK: - Marker parsing

    @Test func ownershipIgnoresTheVersionSoOlderEntriesAreStillOurs() {
        #expect(AgentHookCommand.isSpacesOwned(command(event: .done, version: 0)))
        #expect(AgentHookCommand.isSpacesOwned(command(event: .done, version: AgentHookCommand.hookVersion)))
        // A pre-versioning entry, as the first shipped build would have written it.
        #expect(AgentHookCommand.isSpacesOwned("'/usr/local/bin/spaces' agent signal done || true # spaces-agent-hook"))
        #expect(!AgentHookCommand.isSpacesOwned("echo hello # some-other-tool"))
    }

    @Test func embeddedVersionReadsTheWholeDigitRun() {
        #expect(AgentHookCommand.embeddedVersion(in: command(event: .done, version: 1)) == 1)
        // The bug this guards: matching "v1" as a prefix would read v10 as version 1 and call a
        // far-newer hook current.
        #expect(AgentHookCommand.embeddedVersion(in: command(event: .done, version: 10)) == 10)
        #expect(AgentHookCommand.embeddedVersion(in: command(event: .done, version: 203)) == 203)
        #expect(AgentHookCommand.embeddedVersion(in: "# spaces-agent-hook") == nil)
        #expect(AgentHookCommand.embeddedVersion(in: "no marker here") == nil)
    }

    @Test func currencyIsExactAboutTheVersion() {
        #expect(AgentHookCommand.isCurrent(command(event: .done, version: AgentHookCommand.hookVersion)))
        #expect(!AgentHookCommand.isCurrent(command(event: .done, version: 0)))
        #expect(!AgentHookCommand.isCurrent(command(event: .done, version: AgentHookCommand.hookVersion + 1)))
        #expect(!AgentHookCommand.isCurrent("# spaces-agent-hook"))
    }

    @Test func generatedCommandsCarryTheCurrentVersion() {
        let generated = AgentHookCommand.signalCommand(event: .working, spacesExecutablePath: "/usr/local/bin/spaces")
        #expect(AgentHookCommand.isSpacesOwned(generated))
        #expect(AgentHookCommand.isCurrent(generated))
    }

    // MARK: - JSON writer install state

    @Test func installStateIsNotInstalledWithoutASpacesEntry() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")

        #expect(AgentHookJSONWriter.installState(fileURL: file, bindings: bindings) == .notInstalled)

        // A file holding only the user's own hooks is still "not installed", not "outdated".
        try writeHooks(["SessionStart": [group("echo mine")]], to: file)
        #expect(AgentHookJSONWriter.installState(fileURL: file, bindings: bindings) == .notInstalled)
    }

    @Test func installStateIsCurrentWhenEveryBoundEventCarriesACurrentEntry() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        try AgentHookJSONWriter.install(fileURL: file, bindings: bindings, spacesExecutablePath: "/usr/local/bin/spaces")

        #expect(AgentHookJSONWriter.installState(fileURL: file, bindings: bindings) == .current)
    }

    @Test func installStateIsOutdatedWhenEntriesCarryAnOlderVersion() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        try writeHooks(
            ["SessionStart": [group(command(event: .initialize, version: 0))], "Stop": [group(command(event: .done, version: 0))]], to: file)

        #expect(AgentHookJSONWriter.installState(fileURL: file, bindings: bindings) == .outdated)
    }

    /// The case a boolean `hooksInstalled` could never express: this build binds an event the build
    /// that wrote the config did not, so the hooks present are real but incomplete.
    @Test func installStateIsOutdatedWhenThisBuildBindsAnEventTheConfigLacks() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        try writeHooks(["SessionStart": [group(command(event: .initialize, version: AgentHookCommand.hookVersion))]], to: file)

        #expect(AgentHookJSONWriter.installState(fileURL: file, bindings: bindings) == .outdated)
    }

    // MARK: - The reinstall invariant

    /// Reinstalling over an older version must *replace* the old entry, not append beside it. This is
    /// the whole reason `isSpacesOwned` stays version-less; if stripping ever became version-aware,
    /// every Spaces upgrade would leave a second, stale hook firing on every event.
    @Test func reinstallReplacesOlderVersionEntriesAndPreservesTheUsersOwnHooks() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        try writeHooks(
            [
                "SessionStart": [group(command(event: .initialize, version: 0)), group("echo my-own-session-hook")],
                "Stop": [group(command(event: .done, version: 0))],
            ], to: file)

        try AgentHookJSONWriter.install(fileURL: file, bindings: bindings, spacesExecutablePath: "/usr/local/bin/spaces")

        let sessionStart = try readCommands(file, eventName: "SessionStart")
        #expect(sessionStart.filter(AgentHookCommand.isSpacesOwned).count == 1)
        #expect(!sessionStart.contains { AgentHookCommand.embeddedVersion(in: $0) == 0 })
        #expect(sessionStart.contains("echo my-own-session-hook"))

        let stop = try readCommands(file, eventName: "Stop")
        #expect(stop.filter(AgentHookCommand.isSpacesOwned).count == 1)

        #expect(AgentHookJSONWriter.installState(fileURL: file, bindings: bindings) == .current)
    }

    // MARK: - Ending a block

    /// Every supported agent must bind an event that fires *after* a permission prompt is answered.
    ///
    /// The pre-tool hooks alone cannot do it: Claude Code and Codex both fire `PreToolUse` before the
    /// permission decision, so the `blocked` a gated tool raises always lands after that tool's own
    /// `working`. With only `PreToolUse` bound, a row stays `waiting` for the entire run of the approved
    /// tool and — when that tool is the turn's last — right through to `Stop`, never returning to
    /// `working` at all. `PostToolUse` is the first thing either agent emits once the human has
    /// answered, because it proves the tool actually ran.
    ///
    /// Claude Code splits that evidence by outcome — `PostToolUse` on success, `PostToolUseFailure`
    /// on failure or interrupt, never both — so binding only the success half would strand every
    /// approved command that exits non-zero, which is the outcome a gated command most often has.
    /// Codex has no failure variant, so its single `PostToolUse` carries both outcomes.
    @Test func everyAgentReportsWorkingOnceAnAnsweredPermissionPromptLetsTheToolRun() {
        for agent in [CodingAgent.claudeCode, .codex] {
            let bindings = agent.jsonEventBindings
            #expect(bindings.contains { $0.eventName == "PermissionRequest" && $0.event == .blocked })
            #expect(bindings.contains { $0.eventName == "PreToolUse" && $0.event == .working })
            #expect(bindings.contains { $0.eventName == "PostToolUse" && $0.event == .working })
        }
        #expect(CodingAgent.claudeCode.jsonEventBindings.contains { $0.eventName == "PostToolUseFailure" && $0.event == .working })
        // Codex's hook registry has no `PostToolUseFailure`; binding it would write an entry codex
        // never fires.
        #expect(!CodingAgent.codex.jsonEventBindings.contains { $0.eventName == "PostToolUseFailure" })

        // opencode is the one agent that reports the answer itself, so it need not wait for the tool to
        // finish: `permission.replied` fires the moment the human allows or rejects.
        let plugin = AgentHookOpencodePluginWriter.pluginContents(spacesExecutablePath: "/usr/local/bin/spaces")
        #expect(plugin.contains("permission.asked") && plugin.contains("signal(\"blocked\")"))
        let repliedLine = plugin.split(separator: "\n").first { $0.contains("permission.replied") }
        #expect(repliedLine?.contains("signal(\"working\")") == true)
    }

    // MARK: - opencode plugin

    @Test func opencodePluginStateTracksTheHeaderVersion() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let plugin = directory.appendingPathComponent(AgentHookOpencodePluginWriter.pluginFileName)

        #expect(AgentHookOpencodePluginWriter.installState(pluginURL: plugin) == .notInstalled)

        try AgentHookOpencodePluginWriter.install(pluginURL: plugin, spacesExecutablePath: "/usr/local/bin/spaces")
        #expect(AgentHookOpencodePluginWriter.installState(pluginURL: plugin) == .current)

        // A plugin an older Spaces wrote: ours, but not what this build emits.
        let stale = try String(contentsOf: plugin, encoding: .utf8).replacingOccurrences(
            of: AgentHookCommand.versionedMarker(), with: AgentHookCommand.versionedMarker(0))
        try stale.write(to: plugin, atomically: true, encoding: .utf8)
        #expect(AgentHookOpencodePluginWriter.installState(pluginURL: plugin) == .outdated)
    }

    // MARK: - Codex composes two files

    /// Codex will not run `hooks.json` until `features.hooks = true`. Current entries with the flag
    /// off are `.outdated` — the hooks exist but cannot fire, and reinstalling sets the flag.
    @Test func codexIsOutdatedWhenItsHooksAreCurrentButTheFeatureFlagIsOff() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexDirectory = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try AgentHookJSONWriter.install(
            fileURL: codexDirectory.appendingPathComponent("hooks.json"), bindings: CodingAgent.codex.jsonEventBindings,
            spacesExecutablePath: "/usr/local/bin/spaces")

        let disabledCodex = try makeCodexFeatureListExecutable(in: home, enabled: false)
        #expect(CodingAgent.codex.installState(home: home, fileManager: .default, agentExecutablePath: disabledCodex) == .outdated)

        let enabledCodex = try makeCodexFeatureListExecutable(in: home, enabled: true)
        #expect(CodingAgent.codex.installState(home: home, fileManager: .default, agentExecutablePath: enabledCodex) == .current)
    }
}
