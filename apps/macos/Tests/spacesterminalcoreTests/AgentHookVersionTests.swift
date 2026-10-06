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

    /// Creates a real, executable stand-in for the `spaces` binary inside `directory` and returns its
    /// path. A test asserting `.current` passes it as the installed CLI path, unlike the placeholder text
    /// `/usr/local/bin/spaces` other tests here use for a fixture already outdated by version or a plain
    /// string/marker comparison.
    private func makeFakeSpacesExecutable(in directory: URL) throws -> String {
        let executable = directory.appendingPathComponent("spaces")
        try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable.path
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

    /// `embeddedExecutablePath` must be the exact inverse of `shellQuoted`: whatever path `signalCommand`
    /// quotes into a command, reading it back must return byte-for-byte, including a path holding a
    /// single quote (the one character `shellQuoted` escapes) and a path holding a space (the reason the
    /// path is quoted at all).
    @Test func embeddedExecutablePathRoundTripsShellQuoting() {
        for path in ["/usr/local/bin/spaces", "/Users/a b/bin/spaces", "/Users/o'brien/bin/spaces", "'''"] {
            let generated = AgentHookCommand.signalCommand(event: .done, spacesExecutablePath: path)
            #expect(AgentHookCommand.embeddedExecutablePath(in: generated) == path)
        }
        // Text that is not a quoted-path command at all: no marker, no leading quote.
        #expect(AgentHookCommand.embeddedExecutablePath(in: "echo hello # some-other-tool") == nil)
        #expect(AgentHookCommand.embeddedExecutablePath(in: "not-quoted-at-all") == nil)
        // An opening quote with no closing quote is malformed, not a zero-length path.
        #expect(AgentHookCommand.embeddedExecutablePath(in: "'/no/closing/quote") == nil)
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

        #expect(AgentHookJSONWriter.installState(fileURL: file, bindings: bindings, spacesExecutablePath: nil) == .notInstalled)

        // A file holding only the user's own hooks is still "not installed", not "outdated".
        try writeHooks(["SessionStart": [group("echo mine")]], to: file)
        #expect(AgentHookJSONWriter.installState(fileURL: file, bindings: bindings, spacesExecutablePath: nil) == .notInstalled)
    }

    @Test func installStateIsCurrentWhenEveryBoundEventCarriesACurrentEntry() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let spacesPath = try makeFakeSpacesExecutable(in: directory)
        try AgentHookJSONWriter.install(fileURL: file, bindings: bindings, spacesExecutablePath: spacesPath)

        #expect(AgentHookJSONWriter.installState(fileURL: file, bindings: bindings, spacesExecutablePath: spacesPath) == .current)
    }

    /// The status rule: a current, fully-bound config still reports `.outdated` unless the `spaces` path
    /// its hook commands embed is the installed CLI, so a config naming a development build's CLI (or a
    /// CLI that has since moved or gone) is offered the reinstall that repairs it. With no installed CLI
    /// nothing matches.
    @Test func installStateGoesOutdatedWhenTheEmbeddedSpacesPathIsNotTheInstalledCLI() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let spacesPath = try makeFakeSpacesExecutable(in: directory)
        try AgentHookJSONWriter.install(fileURL: file, bindings: bindings, spacesExecutablePath: spacesPath)
        #expect(AgentHookJSONWriter.installState(fileURL: file, bindings: bindings, spacesExecutablePath: spacesPath) == .current)

        #expect(
            AgentHookJSONWriter.installState(fileURL: file, bindings: bindings, spacesExecutablePath: "/Applications/Spaces.app/spaces") == .outdated)
        #expect(AgentHookJSONWriter.installState(fileURL: file, bindings: bindings, spacesExecutablePath: nil) == .outdated)
    }

    /// Pins the same rule against the codex `hooks.json` shape directly, independent of
    /// `CodingAgent.codex.installState`'s feature-toggle and trust-record layers, so a failure here
    /// points straight at `AgentHookJSONWriter` rather than codex's own state ladder.
    @Test func installStateGoesOutdatedWhenTheCodexEmbeddedSpacesPathIsNotTheInstalledCLI() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("hooks.json")
        let codexBindings = CodingAgent.codex.jsonEventBindings
        let spacesPath = try makeFakeSpacesExecutable(in: directory)
        try AgentHookJSONWriter.install(fileURL: file, bindings: codexBindings, spacesExecutablePath: spacesPath)
        #expect(AgentHookJSONWriter.installState(fileURL: file, bindings: codexBindings, spacesExecutablePath: spacesPath) == .current)

        #expect(
            AgentHookJSONWriter.installState(fileURL: file, bindings: codexBindings, spacesExecutablePath: "/Applications/Spaces.app/spaces")
                == .outdated)
    }

    @Test func installStateIsOutdatedWhenEntriesCarryAnOlderVersion() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        try writeHooks(
            ["SessionStart": [group(command(event: .initialize, version: 0))], "Stop": [group(command(event: .done, version: 0))]], to: file)

        #expect(AgentHookJSONWriter.installState(fileURL: file, bindings: bindings, spacesExecutablePath: "/usr/local/bin/spaces") == .outdated)
    }

    /// The case a boolean `hooksInstalled` could never express: this build binds an event the build
    /// that wrote the config did not, so the hooks present are real but incomplete.
    @Test func installStateIsOutdatedWhenThisBuildBindsAnEventTheConfigLacks() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        try writeHooks(["SessionStart": [group(command(event: .initialize, version: AgentHookCommand.hookVersion))]], to: file)

        #expect(AgentHookJSONWriter.installState(fileURL: file, bindings: bindings, spacesExecutablePath: "/usr/local/bin/spaces") == .outdated)
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

        let spacesPath = try makeFakeSpacesExecutable(in: directory)
        try AgentHookJSONWriter.install(fileURL: file, bindings: bindings, spacesExecutablePath: spacesPath)

        let sessionStart = try readCommands(file, eventName: "SessionStart")
        #expect(sessionStart.filter(AgentHookCommand.isSpacesOwned).count == 1)
        #expect(!sessionStart.contains { AgentHookCommand.embeddedVersion(in: $0) == 0 })
        #expect(sessionStart.contains("echo my-own-session-hook"))

        let stop = try readCommands(file, eventName: "Stop")
        #expect(stop.filter(AgentHookCommand.isSpacesOwned).count == 1)

        #expect(AgentHookJSONWriter.installState(fileURL: file, bindings: bindings, spacesExecutablePath: spacesPath) == .current)
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
        #expect(plugin.contains("permission.asked") && plugin.contains("signal(\"blocked\", sessionID)"))
        let repliedLine = plugin.split(separator: "\n").first { $0.contains("permission.replied") }
        #expect(repliedLine?.contains("signal(\"working\", sessionID)") == true)
    }

    // MARK: - Reporting an exit

    /// A codex session that ends reports it itself. Without the binding, a codex agent row only stops
    /// being live when the daemon's exited-session sweep notices, which is coarser and later.
    @Test func everyAgentWithASessionEndEventReportsItsOwnExit() throws {
        for agent in [CodingAgent.claudeCode, .codex] {
            #expect(agent.jsonEventBindings.contains { $0.eventName == "SessionEnd" && $0.event == .exit })
            #expect(agent.jsonEventBindings.filter { $0.event == .exit }.count == 1)
        }

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("hooks.json")
        try AgentHookJSONWriter.install(fileURL: file, bindings: CodingAgent.codex.jsonEventBindings, spacesExecutablePath: "/usr/local/bin/spaces")
        let sessionEnd = try readCommands(file, eventName: "SessionEnd")
        #expect(sessionEnd.count == 1)
        #expect(sessionEnd[0].contains("agent signal exit"))

        // The writer writes what the agent binds and nothing else: an event set without a session-end
        // event produces no entry for one.
        let other = directory.appendingPathComponent("settings.json")
        try AgentHookJSONWriter.install(fileURL: other, bindings: bindings, spacesExecutablePath: "/usr/local/bin/spaces")
        #expect(try readCommands(other, eventName: "SessionEnd").isEmpty)
    }

    /// Bumping the hook version is what re-offers the update to a user carrying the previous release's
    /// hooks. Pinned against the literal previous version rather than `hookVersion - 1`, so a bump that
    /// forgets what it invalidates cannot pass by arithmetic.
    @Test func hooksWrittenByThePreviousReleaseReadAsOutdated() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        try writeHooks(
            ["SessionStart": [group(command(event: .initialize, version: 4))], "Stop": [group(command(event: .done, version: 4))]], to: file)

        #expect(AgentHookCommand.hookVersion == 5)
        #expect(AgentHookJSONWriter.installState(fileURL: file, bindings: bindings, spacesExecutablePath: "/usr/local/bin/spaces") == .outdated)
    }

    // MARK: - opencode plugin

    /// opencode hands its plugin a JavaScript event rather than a payload on stdin, so the id of the
    /// conversation a signal belongs to reaches the CLI as an argument. The startup signal is the one
    /// that reports none: opencode loads its plugins before any session exists.
    @Test func opencodePluginReportsTheAgentsSessionIDAsAnArgument() {
        let plugin = AgentHookOpencodePluginWriter.pluginContents(spacesExecutablePath: "/usr/local/bin/spaces")
        #expect(plugin.contains("agent signal ${event} --agent-session ${sessionID}"))
        #expect(plugin.contains("event.properties?.sessionID"))
        #expect(plugin.contains("signal(\"working\", input?.sessionID)"))
        let initLine = plugin.split(separator: "\n").first { $0.contains("signal(\"init\"") }
        #expect(initLine?.contains("await signal(\"init\")") == true)
    }

    @Test func opencodePluginStateTracksTheHeaderVersion() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let plugin = directory.appendingPathComponent(AgentHookOpencodePluginWriter.pluginFileName)

        #expect(AgentHookOpencodePluginWriter.installState(pluginURL: plugin, spacesExecutablePath: nil) == .notInstalled)

        let spacesPath = try makeFakeSpacesExecutable(in: directory)
        try AgentHookOpencodePluginWriter.install(pluginURL: plugin, spacesExecutablePath: spacesPath)
        #expect(AgentHookOpencodePluginWriter.installState(pluginURL: plugin, spacesExecutablePath: spacesPath) == .current)

        // A plugin an older Spaces wrote: ours, but not what this build emits.
        let stale = try String(contentsOf: plugin, encoding: .utf8).replacingOccurrences(
            of: AgentHookCommand.versionedMarker(), with: AgentHookCommand.versionedMarker(0))
        try stale.write(to: plugin, atomically: true, encoding: .utf8)
        #expect(AgentHookOpencodePluginWriter.installState(pluginURL: plugin, spacesExecutablePath: spacesPath) == .outdated)
    }

    /// The same status rule, pinned against the opencode plugin's own state function: a current plugin
    /// still reports `.outdated` unless the `spaces` path baked into its `SPACES_CLI` constant is the
    /// installed CLI.
    @Test func opencodePluginStateGoesOutdatedWhenItsEmbeddedCLIPathIsNotTheInstalledCLI() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let plugin = directory.appendingPathComponent(AgentHookOpencodePluginWriter.pluginFileName)
        let spacesPath = try makeFakeSpacesExecutable(in: directory)
        try AgentHookOpencodePluginWriter.install(pluginURL: plugin, spacesExecutablePath: spacesPath)
        #expect(AgentHookOpencodePluginWriter.installState(pluginURL: plugin, spacesExecutablePath: spacesPath) == .current)

        #expect(AgentHookOpencodePluginWriter.installState(pluginURL: plugin, spacesExecutablePath: "/Applications/Spaces.app/spaces") == .outdated)
        #expect(AgentHookOpencodePluginWriter.installState(pluginURL: plugin, spacesExecutablePath: nil) == .outdated)
    }

    // MARK: - Codex's own config

    /// The canonical path of `url`, as `realpath(3)` reports it and as Codex records it in a state table
    /// name: `/private/var/...` for a temporary directory, not the `/var/...` alias Foundation's own
    /// symlink resolution returns to. Spelled out here rather than taken from the product, so the two
    /// have to agree.
    private func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Codex will not run `hooks.json` until `features.hooks = true`. Current entries with the flag
    /// off are `.outdated`: the hooks exist but cannot fire, and reinstalling sets the flag. With the
    /// flag on, the files are current, and whether Codex trusts them is Codex's to say.
    @Test func codexIsOutdatedWhenItsHooksAreCurrentButTheFeatureFlagIsOff() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexDirectory = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let spacesPath = try makeFakeSpacesExecutable(in: home)
        try AgentHookJSONWriter.install(
            fileURL: codexDirectory.appendingPathComponent("hooks.json"), bindings: CodingAgent.codex.jsonEventBindings,
            spacesExecutablePath: spacesPath)

        let disabledCodex = try makeCodexFeatureListExecutable(in: home, enabled: false)
        #expect(
            CodingAgent.codex.configState(home: home, fileManager: .default, agentExecutablePath: disabledCodex, spacesExecutablePath: spacesPath)
                == .outdated)

        let enabledCodex = try makeCodexFeatureListExecutable(in: home, enabled: true)
        #expect(
            CodingAgent.codex.configState(home: home, fileManager: .default, agentExecutablePath: enabledCodex, spacesExecutablePath: spacesPath)
                == .current)
    }

    /// Codex canonicalizes its home before naming a hook, so a home under `/var` or `/tmp` (a link into
    /// a temporary directory, and every home these tests build, since `NSTemporaryDirectory` sits under
    /// `/var/folders`) is named under `/private`. Naming it the other way would match none of Codex's
    /// entries and leave the row out of date for good, so the canonical form is pinned here.
    @Test func codexNamesAHookUnderTheCanonicalPathOfItsHome() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexDirectory = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let hooksFileURL = codexDirectory.appendingPathComponent("hooks.json")

        let sourcePath = AgentHookCodexTrust.codexSourcePath(for: hooksFileURL)

        #expect(sourcePath.hasPrefix("/private/"), "A temporary home is named under its canonical path")
        #expect(sourcePath.hasSuffix("/.codex/hooks.json"))
        #expect(sourcePath == (realPath(codexDirectory) as NSString).appendingPathComponent("hooks.json"))
    }
}
