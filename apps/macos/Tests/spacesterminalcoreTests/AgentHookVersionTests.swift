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
        #expect(AgentHookJSONWriter.installState(fileURL: file, bindings: bindings) == .outdated)
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

        #expect(AgentHookOpencodePluginWriter.installState(pluginURL: plugin) == .notInstalled)

        try AgentHookOpencodePluginWriter.install(pluginURL: plugin, spacesExecutablePath: "/usr/local/bin/spaces")
        #expect(AgentHookOpencodePluginWriter.installState(pluginURL: plugin) == .current)

        // A plugin an older Spaces wrote: ours, but not what this build emits.
        let stale = try String(contentsOf: plugin, encoding: .utf8).replacingOccurrences(
            of: AgentHookCommand.versionedMarker(), with: AgentHookCommand.versionedMarker(0))
        try stale.write(to: plugin, atomically: true, encoding: .utf8)
        #expect(AgentHookOpencodePluginWriter.installState(pluginURL: plugin) == .outdated)
    }

    // MARK: - Codex composes three things

    /// The state names Codex gives the Spaces entries of a freshly written `hooks.json`: one group per
    /// event, one hook inside it, so both indices are 0. Spelled out rather than derived, so the key
    /// shape is pinned independently of the code that builds it.
    private static let codexStateKeyEvents = [
        "session_start", "user_prompt_submit", "pre_tool_use", "post_tool_use", "permission_request", "stop", "session_end",
    ]

    /// The canonical path of `url`, as `realpath(3)` reports it and as Codex records it in a state table
    /// name: `/private/var/...` for a temporary directory, not the `/var/...` alias Foundation's own
    /// symlink resolution returns to. Spelled out here rather than taken from the product, so the two
    /// have to agree.
    private func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The name Codex gives `hooksFileURL`: its home canonicalized, with the file name appended.
    private func codexKeyPath(_ hooksFileURL: URL) -> String {
        (realPath(hooksFileURL.deletingLastPathComponent()) as NSString).appendingPathComponent(hooksFileURL.lastPathComponent)
    }

    /// The `config.toml` tables Codex writes once the user approves the hooks, for the Spaces entry of
    /// every bound event. `enabled` is written only when given, matching Codex, which omits it for an
    /// entry nobody has switched off.
    ///
    /// `keyPath` defaults to the name Codex gives the file: its home canonicalized, with the file name
    /// appended; a caller passes it explicitly to write a table under some other name.
    private func codexTrustTables(hooksFileURL: URL, keyPath: String? = nil, enabled: Bool? = nil, skipping skippedEvent: String? = nil) -> String {
        let path = keyPath ?? codexKeyPath(hooksFileURL)
        return Self.codexStateKeyEvents.filter { $0 != skippedEvent }.map { event in
            var table = "\n[hooks.state.\"\(path):\(event):0:0\"]\n"
            if let enabled { table += "enabled = \(enabled)\n" }
            return table + "trusted_hash = \"sha256:0f0f\"\n"
        }.joined()
    }

    private func writeCodexHooksOfVersion(_ version: Int, to url: URL) throws {
        var hooks: [String: Any] = [:]
        for binding in CodingAgent.codex.jsonEventBindings { hooks[binding.eventName] = [group(command(event: binding.event, version: version))] }
        try writeHooks(hooks, to: url)
    }

    /// Codex will not run `hooks.json` until `features.hooks = true`. Current entries with the flag
    /// off are `.outdated` — the hooks exist but cannot fire, and reinstalling sets the flag.
    @Test func codexIsOutdatedWhenItsHooksAreCurrentButTheFeatureFlagIsOff() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexDirectory = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let hooksFileURL = codexDirectory.appendingPathComponent("hooks.json")
        try AgentHookJSONWriter.install(
            fileURL: hooksFileURL, bindings: CodingAgent.codex.jsonEventBindings, spacesExecutablePath: "/usr/local/bin/spaces")
        try codexTrustTables(hooksFileURL: hooksFileURL).write(
            to: codexDirectory.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let disabledCodex = try makeCodexFeatureListExecutable(in: home, enabled: false)
        #expect(CodingAgent.codex.installState(home: home, fileManager: .default, agentExecutablePath: disabledCodex) == .outdated)

        let enabledCodex = try makeCodexFeatureListExecutable(in: home, enabled: true)
        #expect(CodingAgent.codex.installState(home: home, fileManager: .default, agentExecutablePath: enabledCodex) == .current)
    }

    /// Codex runs no hook it has not been told to trust, so hooks that are present, current, and
    /// enabled still report nothing until the user approves them in Codex. The rungs, in the order
    /// their remedies apply: nothing installed, entries an older Spaces wrote (reinstall), entries
    /// reviewed and then switched off in Codex, entries this build wrote that were never reviewed,
    /// entries trusted.
    @Test func codexRunsThroughTheWholeStateLadderFromNotInstalledToTrusted() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexDirectory = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let hooksFileURL = codexDirectory.appendingPathComponent("hooks.json")
        let configURL = codexDirectory.appendingPathComponent("config.toml")
        let codex = try makeCodexFeatureListExecutable(in: home, enabled: true)
        func state() -> AgentHookInstallState { CodingAgent.codex.installState(home: home, fileManager: .default, agentExecutablePath: codex) }

        #expect(Self.codexStateKeyEvents.count == CodingAgent.codex.jsonEventBindings.count)
        #expect(state() == .notInstalled)

        // Entries an older Spaces wrote read as out of date even where Codex already trusts them: the
        // hooks the user approved are not the hooks this build wants to run.
        try writeCodexHooksOfVersion(AgentHookCommand.hookVersion - 1, to: hooksFileURL)
        try codexTrustTables(hooksFileURL: hooksFileURL).write(to: configURL, atomically: true, encoding: .utf8)
        #expect(state() == .outdated)

        try AgentHookJSONWriter.install(
            fileURL: hooksFileURL, bindings: CodingAgent.codex.jsonEventBindings, spacesExecutablePath: "/usr/local/bin/spaces")
        try "[features]\nhooks = true\n".write(to: configURL, atomically: true, encoding: .utf8)
        #expect(state() == .awaitingTrust)

        // One entry left unreviewed is enough: the events it covers report nothing.
        try codexTrustTables(hooksFileURL: hooksFileURL, skipping: "session_end").write(to: configURL, atomically: true, encoding: .utf8)
        #expect(state() == .awaitingTrust)

        // Reviewed and then switched off is its own answer, not an outstanding review: Codex asks for
        // no review of a hook it was told to stop running, so the user is sent to switch it back on.
        try codexTrustTables(hooksFileURL: hooksFileURL, enabled: false).write(to: configURL, atomically: true, encoding: .utf8)
        #expect(state() == .disabledByAgent)

        // A switched-off entry beside an unreviewed one still reads as switched off: it stays off
        // however the review goes, so it is the first thing to put right.
        try (codexTrustTables(hooksFileURL: hooksFileURL, enabled: false, skipping: "session_end")).write(
            to: configURL, atomically: true, encoding: .utf8)
        #expect(state() == .disabledByAgent)

        try codexTrustTables(hooksFileURL: hooksFileURL, enabled: true).write(to: configURL, atomically: true, encoding: .utf8)
        #expect(state() == .current)
    }

    /// Codex canonicalizes its home before naming a hook, so a home under `/var` or `/tmp` (a link into
    /// a temporary directory, and every home these tests build, since `NSTemporaryDirectory` sits under
    /// `/var/folders`) is recorded under `/private`. Naming it the other way leaves every entry reading
    /// as unreviewed forever and its records never cleared, so the canonical form is pinned here.
    @Test func codexNamesAHookUnderTheCanonicalPathOfItsHome() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexDirectory = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let hooksFileURL = codexDirectory.appendingPathComponent("hooks.json")

        let keyPath = AgentHookCodexTrustState.codexKeyPath(for: hooksFileURL)

        #expect(keyPath.hasPrefix("/private/"), "A temporary home is named under its canonical path")
        #expect(keyPath.hasSuffix("/.codex/hooks.json"))
        #expect(keyPath == codexKeyPath(hooksFileURL))
    }

    /// A codex home reached through a symlink is a supported setup, and Codex resolves its home before
    /// naming a hook: it keys the state tables by the directory the link points at. Building the key
    /// from the path Spaces walked instead would leave every hook in such a home reading as unreviewed
    /// no matter how often the user approves it, and would leave its records behind on every reinstall.
    @Test func codexTrustFollowsTheResolvedHomeWhenTheCodexDirectoryIsASymlink() throws {
        let enclosing = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: enclosing) }
        let resolvedHome = enclosing.appendingPathComponent("resolved", isDirectory: true)
        let linkedHome = enclosing.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: resolvedHome.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedHome, withDestinationURL: resolvedHome)

        let hooksFileURL = linkedHome.appendingPathComponent(".codex/hooks.json")
        let configURL = linkedHome.appendingPathComponent(".codex/config.toml")
        try AgentHookJSONWriter.install(
            fileURL: hooksFileURL, bindings: CodingAgent.codex.jsonEventBindings, spacesExecutablePath: "/usr/local/bin/spaces")
        let codex = try makeCodexFeatureListExecutable(in: enclosing, enabled: true)
        func state() -> AgentHookInstallState { CodingAgent.codex.installState(home: linkedHome, fileManager: .default, agentExecutablePath: codex) }

        // Tables keyed by the path Spaces walked, which is not the name Codex gives these hooks.
        try codexTrustTables(hooksFileURL: hooksFileURL, keyPath: hooksFileURL.path).write(to: configURL, atomically: true, encoding: .utf8)
        #expect(state() == .awaitingTrust)

        try codexTrustTables(hooksFileURL: hooksFileURL).write(to: configURL, atomically: true, encoding: .utf8)
        #expect(state() == .current)

        // And a rewrite clears exactly those records, so the reinstall leaves nothing claiming the new
        // hooks were approved.
        try AgentHookCodexTrustState.clearTrustRecords(hooksFileURL: hooksFileURL, configURL: configURL, fileManager: .default)
        #expect(!(try String(contentsOf: configURL, encoding: .utf8)).contains("hooks.state"))
        #expect(state() == .awaitingTrust)
    }

    /// Codex names a hook by where it sits in the file, so the Spaces entry of an event the user also
    /// hooks is the second group, not the first. Reading the coordinates back out of the written file
    /// is what keeps the two in step; assuming position 0 would report a trusted hook as untrusted for
    /// every user who has a hook of their own on the same event.
    @Test func codexTrustFollowsTheSpacesEntrysPositionAmongTheUsersOwnHooks() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexDirectory = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let hooksFileURL = codexDirectory.appendingPathComponent("hooks.json")
        let configURL = codexDirectory.appendingPathComponent("config.toml")
        try writeHooks(["Stop": [group("my-own-stop-hook")]], to: hooksFileURL)
        try AgentHookJSONWriter.install(
            fileURL: hooksFileURL, bindings: CodingAgent.codex.jsonEventBindings, spacesExecutablePath: "/usr/local/bin/spaces")
        let codex = try makeCodexFeatureListExecutable(in: home, enabled: true)
        func state() -> AgentHookInstallState { CodingAgent.codex.installState(home: home, fileManager: .default, agentExecutablePath: codex) }

        // Trust recorded for the user's own Stop hook, at group 0, says nothing about the Spaces entry.
        try codexTrustTables(hooksFileURL: hooksFileURL).write(to: configURL, atomically: true, encoding: .utf8)
        #expect(state() == .awaitingTrust)

        let keyPath = codexKeyPath(hooksFileURL)
        let spacesStopTable = "\n[hooks.state.\"\(keyPath):stop:1:0\"]\ntrusted_hash = \"sha256:0f0f\"\n"
        try (codexTrustTables(hooksFileURL: hooksFileURL, skipping: "stop") + spacesStopTable).write(to: configURL, atomically: true, encoding: .utf8)
        #expect(state() == .current)
    }
}
