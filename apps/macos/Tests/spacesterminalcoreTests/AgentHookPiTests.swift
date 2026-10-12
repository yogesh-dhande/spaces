import Foundation
import Testing

@testable import spacesterminalcore

/// The pi extension Spaces writes (verified against pi 1.1.0). The extension runs inside pi, so these tests
/// cover what Spaces controls: the file it writes, what it embeds, and how install state reads it back.
struct AgentHookPiTests {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pi-extension-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func theExtensionCarriesTheOwnershipHeaderAndVersionMarker() {
        let contents = AgentHookPiExtensionWriter.extensionContents(spacesExecutablePath: "/usr/local/bin/spaces")
        #expect(contents.hasPrefix("// spaces-agent-signal: managed by Spaces ("))
        #expect(contents.contains(AgentHookCommand.versionedMarker()))
        #expect(AgentHookCommand.isCurrent(contents))
    }

    @Test func theExtensionBakesInTheCLIPathAsAnEscapedLiteral() {
        let path = #"/Users/it's "me"/back\slash/spaces"#
        let contents = AgentHookPiExtensionWriter.extensionContents(spacesExecutablePath: path)
        #expect(contents.contains(#"const SPACES_CLI = "/Users/it's \"me\"/back\\slash/spaces""#))
        #expect(AgentHookEmbeddedCLIPath.path(in: contents) == path)
    }

    /// Every lifecycle signal the extension sends is present, and an extension loaded outside the
    /// interactive terminal UI or in a pi older than the version floor does nothing.
    @Test func theExtensionMapsPiEventsOntoLifecycleSignals() {
        let contents = AgentHookPiExtensionWriter.extensionContents(spacesExecutablePath: "/usr/local/bin/spaces")
        for event in ["session_start", "input", "before_agent_start", "agent_start", "ui_prompt_start", "ui_prompt_end", "agent_settled", "session_shutdown"] {
            #expect(contents.contains("pi.on(\"\(event)\""), "\(event)")
        }
        for signal in ["init", "working", "blocked", "done", "exit"] { #expect(contents.contains("signal(\"\(signal)\""), "\(signal)") }
        #expect(contents.contains(#"event?.reason !== "quit""#))
        #expect(contents.contains(#"ctx?.mode === "tui""#))
        #expect(contents.contains(#"import { VERSION } from "@earendil-works/pi-coding-agent""#))
        #expect(contents.contains("const MINIMUM_PI_VERSION = [1, 1, 0]"))
        #expect(contents.contains(#"JSON.stringify({ session_id: transcriptPath, transcript_path: transcriptPath })"#))
        #expect(!contents.contains("--agent-session"))
        // Signals are chained, not fired independently: pi does not await its `ui_prompt_*` handlers.
        #expect(contents.contains("queue = queue.then(() => send(event, payload))"))
    }

    @Test func installWritesTheExtensionUnderTheExtensionsDirectory() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let piHome = CodingAgent.pi.configDirectoryURL(home: home)
        let file = AgentHookPiExtensionWriter.extensionURL(piHome: piHome)
        #expect(file.path == home.appendingPathComponent(".pi/agent/extensions/spaces.ts").path)

        try AgentHookPiExtensionWriter.install(extensionURL: file, spacesExecutablePath: "/usr/local/bin/spaces")

        #expect(try String(contentsOf: file, encoding: .utf8) == AgentHookPiExtensionWriter.extensionContents(spacesExecutablePath: "/usr/local/bin/spaces"))
    }

    @Test func installRefusesAnUnmanagedFile() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = AgentHookPiExtensionWriter.extensionURL(piHome: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "export default function () {}\n".write(to: file, atomically: true, encoding: .utf8)

        #expect(throws: AgentHookPiExtensionWriter.UnmanagedExtensionError.self) {
            try AgentHookPiExtensionWriter.install(extensionURL: file, spacesExecutablePath: "/usr/local/bin/spaces")
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "export default function () {}\n")
    }

    @Test func installStateReadsCurrentOutdatedAndNotInstalled() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = AgentHookPiExtensionWriter.extensionURL(piHome: home)
        let cli = "/usr/local/bin/spaces"
        #expect(AgentHookPiExtensionWriter.installState(extensionURL: file, spacesExecutablePath: cli) == .notInstalled)

        try AgentHookPiExtensionWriter.install(extensionURL: file, spacesExecutablePath: cli)
        #expect(AgentHookPiExtensionWriter.installState(extensionURL: file, spacesExecutablePath: cli) == .current)

        // A different embedded CLI path, or no installed CLI at all, never reads current.
        #expect(AgentHookPiExtensionWriter.installState(extensionURL: file, spacesExecutablePath: "/elsewhere/spaces") == .outdated)
        #expect(AgentHookPiExtensionWriter.installState(extensionURL: file, spacesExecutablePath: nil) == .outdated)

        let older = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(
            of: AgentHookCommand.versionedMarker(), with: AgentHookCommand.versionedMarker(AgentHookCommand.hookVersion - 1))
        try older.write(to: file, atomically: true, encoding: .utf8)
        #expect(AgentHookPiExtensionWriter.installState(extensionURL: file, spacesExecutablePath: cli) == .outdated)

        try "export default function () {}\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(AgentHookPiExtensionWriter.installState(extensionURL: file, spacesExecutablePath: cli) == .notInstalled)
    }

    @Test func piBindsNoJSONHookEvents() { #expect(CodingAgent.pi.jsonEventBindings.isEmpty) }

    @Test func piExitsAlwaysCount() {
        #expect(CodingAgent.pi.exitSignalCounts(reportedKey: .unreported, rowSessionKey: nil))
        #expect(CodingAgent.pi.exitSignalCounts(reportedKey: .resumable("a"), rowSessionKey: "b"))
    }
}
