import Foundation
import Testing

@testable import spacesterminalcore

/// The Amp plugin Spaces writes (verified against amp 0.0.1791849701). The plugin runs inside Amp, so these
/// tests cover what Spaces controls: the file it writes, what it embeds, and how install state reads it back.
struct AgentHookAmpTests {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("amp-plugin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func thePluginCarriesTheOwnershipHeaderAndVersionMarker() {
        let contents = AgentHookAmpPluginWriter.pluginContents(spacesExecutablePath: "/usr/local/bin/spaces")
        #expect(contents.hasPrefix("// spaces-agent-signal: managed by Spaces ("))
        #expect(contents.contains(AgentHookCommand.versionedMarker()))
        #expect(AgentHookCommand.isCurrent(contents))
    }

    @Test func thePluginBakesInTheCLIPathAsAnEscapedLiteral() {
        let path = #"/Users/it's "me"/back\slash/spaces"#
        let contents = AgentHookAmpPluginWriter.pluginContents(spacesExecutablePath: path)
        #expect(contents.contains(#"const SPACES_CLI = "/Users/it's \"me\"/back\\slash/spaces""#))
        #expect(AgentHookEmbeddedCLIPath.path(in: contents) == path)
    }

    /// Every lifecycle signal the plugin sends is present, keyed off the active thread, and a plugin loaded
    /// by an Amp without `activeThread.subscribe` registers nothing.
    @Test func thePluginMapsAmpThreadStatesOntoLifecycleSignals() {
        let contents = AgentHookAmpPluginWriter.pluginContents(spacesExecutablePath: "/usr/local/bin/spaces")
        #expect(contents.contains(#"typeof amp?.activeThread?.subscribe !== "function""#))
        #expect(contents.contains("amp.activeThread.subscribe("))
        #expect(contents.contains(#"amp.on("session.start""#))
        #expect(contents.contains(#"signal("init""#))
        for status in ["working", "blocked", "done"] { #expect(contents.contains("forward(\"\(status)\")"), "\(status)") }
        // A reload also disposes the plugin, so exit is left to process detection.
        #expect(!contents.contains("onDispose"))
        #expect(!contents.contains(#""exit""#))
        // The pending reading of an empty session id is Amp's, so the CLI must know the agent.
        #expect(contents.contains(#"["agent", "signal", event, "--agent", "amp"]"#))
        #expect(contents.contains(#"JSON.stringify({ session_id: id ?? "" })"#))
        // Leaving a busy thread for one that is not working settles the row.
        #expect(contents.contains(#"else if (rowBusy) forward("done")"#))
        #expect(contents.contains(#""awaiting-approval""#))
        #expect(!contents.contains("agent.end"))
        #expect(!contents.contains("transcript_path"))
        // Signals are chained so a late `working` cannot land after a `done`.
        #expect(contents.contains("queue = queue.then(() => send(event, payload))"))
    }

    @Test func installWritesThePluginUnderThePluginsDirectory() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let ampHome = CodingAgent.amp.configDirectoryURL(home: home)
        let file = AgentHookAmpPluginWriter.pluginURL(ampHome: ampHome)
        #expect(file.path == home.appendingPathComponent(".config/amp/plugins/spaces.ts").path)

        try AgentHookAmpPluginWriter.install(pluginURL: file, spacesExecutablePath: "/usr/local/bin/spaces")

        #expect(try String(contentsOf: file, encoding: .utf8) == AgentHookAmpPluginWriter.pluginContents(spacesExecutablePath: "/usr/local/bin/spaces"))
    }

    @Test func installRefusesAnUnmanagedFile() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = AgentHookAmpPluginWriter.pluginURL(ampHome: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "export default function () {}\n".write(to: file, atomically: true, encoding: .utf8)

        #expect(throws: AgentHookAmpPluginWriter.UnmanagedPluginError.self) {
            try AgentHookAmpPluginWriter.install(pluginURL: file, spacesExecutablePath: "/usr/local/bin/spaces")
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "export default function () {}\n")
    }

    @Test func installStateReadsCurrentOutdatedAndNotInstalled() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = AgentHookAmpPluginWriter.pluginURL(ampHome: home)
        let cli = "/usr/local/bin/spaces"
        #expect(AgentHookAmpPluginWriter.installState(pluginURL: file, spacesExecutablePath: cli) == .notInstalled)

        try AgentHookAmpPluginWriter.install(pluginURL: file, spacesExecutablePath: cli)
        #expect(AgentHookAmpPluginWriter.installState(pluginURL: file, spacesExecutablePath: cli) == .current)

        // A different embedded CLI path, or no installed CLI at all, never reads current.
        #expect(AgentHookAmpPluginWriter.installState(pluginURL: file, spacesExecutablePath: "/elsewhere/spaces") == .outdated)
        #expect(AgentHookAmpPluginWriter.installState(pluginURL: file, spacesExecutablePath: nil) == .outdated)

        let older = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(
            of: AgentHookCommand.versionedMarker(), with: AgentHookCommand.versionedMarker(AgentHookCommand.hookVersion - 1))
        try older.write(to: file, atomically: true, encoding: .utf8)
        #expect(AgentHookAmpPluginWriter.installState(pluginURL: file, spacesExecutablePath: cli) == .outdated)

        try "export default function () {}\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(AgentHookAmpPluginWriter.installState(pluginURL: file, spacesExecutablePath: cli) == .notInstalled)
    }

    /// The plugin reports a bare thread id, which the CLI treats as resumable as it stands (Amp keeps no
    /// transcript file to check), and an empty `session_id` (a new thread without an id yet) as pending.
    @Test func aThreadIdPayloadIsResumableAndAnEmptyOneIsPending() {
        let payload = Data(#"{"session_id":"T-0192abcd-0000-4000-8000-000000000001"}"#.utf8)
        #expect(AgentHookSessionKey.report(inHookPayload: payload, agent: .amp) == .resumable("T-0192abcd-0000-4000-8000-000000000001"))
        #expect(AgentHookSessionKey.report(inHookPayload: Data(#"{"session_id":""}"#.utf8), agent: .amp) == .pending)
        #expect(AgentHookSessionKey.report(inHookPayload: Data(), agent: .amp) == .unreported)
    }

    @Test func ampBindsNoJSONHookEvents() { #expect(CodingAgent.amp.jsonEventBindings.isEmpty) }

    @Test func ampExitsAlwaysCount() {
        #expect(CodingAgent.amp.exitSignalCounts(reportedKey: .unreported, rowSessionKey: nil))
        #expect(CodingAgent.amp.exitSignalCounts(reportedKey: .resumable("a"), rowSessionKey: "b"))
    }
}
