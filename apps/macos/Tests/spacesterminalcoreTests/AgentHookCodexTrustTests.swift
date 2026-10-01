import Foundation
import Testing

@testable import spacesterminalcore

/// Codex's trust in the Spaces hooks is read and recorded through Codex itself, against
/// `FakeCodexAppServer`. What these pin: Spaces trusts exactly the entries it would write on this
/// device and nothing else, the row's state follows what Codex reports about those entries, and every
/// way Codex can fail to answer reaches the caller as Codex's own reason.
struct AgentHookCodexTrustTests {
    private let spacesPath = "/Applications/Spaces.app/Contents/Resources/spaces"

    private func makeCodexHome() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codex-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func hooksFile(_ codexHome: URL) -> URL { codexHome.appendingPathComponent("hooks.json") }
    private func configFile(_ codexHome: URL) -> URL { codexHome.appendingPathComponent("config.toml") }
    private func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    private func installSpacesHooks(_ codexHome: URL, spacesPath: String? = nil) throws {
        try AgentHookJSONWriter.install(
            fileURL: hooksFile(codexHome), bindings: CodingAgent.codex.jsonEventBindings, spacesExecutablePath: spacesPath ?? self.spacesPath)
    }

    /// Adds `command` to `eventName` as a group of its own after whatever the file already holds.
    private func appendHook(_ command: String, eventName: String, to codexHome: URL) throws {
        var root = (try JSONSerialization.jsonObject(with: Data(contentsOf: hooksFile(codexHome))) as? [String: Any]) ?? [:]
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        var groups = (hooks[eventName] as? [[String: Any]]) ?? []
        groups.append(["matcher": "", "hooks": [["type": "command", "command": command]]])
        hooks[eventName] = groups
        root["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: root).write(to: hooksFile(codexHome))
    }

    /// Codex's key for every Spaces entry of the file, mapped to its command, as the fake lists them.
    private func listedSpacesCommands(_ codexHome: URL) throws -> [String: String] {
        let fake = FakeCodexAppServer()
        let listed = try AgentHookCodexAppServer.withSession(
            executablePath: "codex", codexHome: codexHome, timeoutSeconds: 5, launcher: fake.launcher
        ) { try $0.listHooks() }
        let commands = Set(
            CodingAgent.codex.jsonEventBindings.map { AgentHookCommand.signalCommand(event: $0.event, spacesExecutablePath: spacesPath) })
        return Dictionary(uniqueKeysWithValues: listed.filter { commands.contains($0.command ?? "") }.map { ($0.key, $0.command ?? "") })
    }

    private func expectedEntries(spacesPath: String? = nil) -> [AgentHookEntry] {
        CodingAgent.codex.jsonEventBindings.map {
            AgentHookEntry(
                eventName: $0.eventName, command: AgentHookCommand.signalCommand(event: $0.event, spacesExecutablePath: spacesPath ?? self.spacesPath)
            )
        }
    }

    private func status(_ codexHome: URL, fake: FakeCodexAppServer) -> AgentHookCodexTrust.Reading {
        AgentHookCodexTrust.status(codexExecutablePath: "codex", codexHome: codexHome, spacesExecutablePath: spacesPath, launcher: fake.launcher)
    }

    private func trust(_ codexHome: URL, fake: FakeCodexAppServer) throws {
        try AgentHookCodexTrust.trust(codexExecutablePath: "codex", codexHome: codexHome, spacesExecutablePath: spacesPath, launcher: fake.launcher)
    }

    // MARK: - Which entries are Spaces'

    /// A trust is consent to run the commands the user was shown, so it reaches exactly the entries
    /// carrying this device's own command for their event. Another tool's hook on the same event, a
    /// lookalike that carries the Spaces marker around a different command, and a hook with the very
    /// same command defined somewhere other than the user hooks file all stay untrusted.
    @Test func trustRecordsOnlyTheEntriesThisDeviceWritesForTheirEvent() throws {
        let codexHome = try makeCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try installSpacesHooks(codexHome)
        let muxy = "'/Applications/Muxy.app/Contents/MacOS/muxy-hook' pre-tool-use"
        let lookalike = "'/tmp/elsewhere/spaces' agent signal done >/dev/null 2>&1 || true # \(AgentHookCommand.versionedMarker())"
        try appendHook(muxy, eventName: "PreToolUse", to: codexHome)
        try appendHook(lookalike, eventName: "Stop", to: codexHome)
        let fake = FakeCodexAppServer()
        let tomlCommand = AgentHookCommand.signalCommand(event: .done, spacesExecutablePath: spacesPath)
        fake.extraListedHooks = [
            AgentHookCodexListedHook(
                key: "\(FakeCodexAppServer.realPath(codexHome.path))/config.toml:stop:0:0", eventName: "stop", command: tomlCommand,
                sourcePath: "\(FakeCodexAppServer.realPath(codexHome.path))/config.toml", source: "user", enabled: true,
                currentHash: FakeCodexAppServer.hash(of: tomlCommand), trustStatus: "untrusted")
        ]

        try trust(codexHome, fake: fake)

        let config = read(configFile(codexHome))
        let spacesKeys = try listedSpacesCommands(codexHome).keys
        #expect(spacesKeys.count == CodingAgent.codex.jsonEventBindings.count)
        for key in spacesKeys { #expect(config.contains("[hooks.state.\"\(key)\"]")) }
        let keyPath = FakeCodexAppServer.hooksFileKeyPath(codexHome: codexHome)
        #expect(!config.contains("\(keyPath):pre_tool_use:1:0"), "Another tool's hook on the same event")
        #expect(!config.contains("\(keyPath):stop:1:0"), "A lookalike carrying the Spaces marker")
        #expect(!config.contains("config.toml:stop:0:0"), "A hook from another configuration layer")
        #expect(status(codexHome, fake: fake) == .init(installState: .current, untrustedEntries: []))
    }

    /// Codex runs no hook the user switched off, whatever its trust says, and Spaces never turns one
    /// back on: a trust leaves a switched-off entry's table exactly as it was, and the row says what the
    /// user has to do in Codex instead.
    @Test func trustLeavesAnEntrySwitchedOffInCodexAlone() throws {
        let codexHome = try makeCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try installSpacesHooks(codexHome)
        let keyPath = FakeCodexAppServer.hooksFileKeyPath(codexHome: codexHome)
        let switchedOff = "[hooks.state.\"\(keyPath):stop:0:0\"]\nenabled = false\n"
        try switchedOff.write(to: configFile(codexHome), atomically: true, encoding: .utf8)
        let fake = FakeCodexAppServer()

        try trust(codexHome, fake: fake)

        let config = read(configFile(codexHome))
        #expect(config.hasPrefix(switchedOff), "The switched-off table gains neither a trust nor an `enabled = true`")
        #expect(config.components(separatedBy: "trusted_hash").count - 1 == CodingAgent.codex.jsonEventBindings.count - 1)
        #expect(status(codexHome, fake: fake).installState == .disabledByAgent)
    }

    // MARK: - What the row says

    @Test func untrustedEntriesReadAsAwaitingTrustAndCarryTheExactCommandsInBindingOrder() throws {
        let codexHome = try makeCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try installSpacesHooks(codexHome)

        #expect(status(codexHome, fake: FakeCodexAppServer()) == .init(installState: .awaitingTrust, untrustedEntries: expectedEntries()))
    }

    /// One untrusted entry is enough: the events it covers report nothing. Only that entry is what the
    /// user is asked to trust.
    @Test func partiallyTrustedEntriesListOnlyTheOnesStillUntrusted() throws {
        let codexHome = try makeCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try installSpacesHooks(codexHome)
        var trusted = try listedSpacesCommands(codexHome)
        let keyPath = FakeCodexAppServer.hooksFileKeyPath(codexHome: codexHome)
        trusted.removeValue(forKey: "\(keyPath):session_end:0:0")
        try FakeCodexAppServer.trustTables(trusted).write(to: configFile(codexHome), atomically: true, encoding: .utf8)

        let reading = status(codexHome, fake: FakeCodexAppServer())

        #expect(reading.installState == .awaitingTrust)
        #expect(reading.untrustedEntries == expectedEntries().filter { $0.eventName == "SessionEnd" })
    }

    /// A trust recorded at some other text (Codex's `modified`) is not a trust of what the file holds.
    @Test func entriesTrustedAtOtherTextReadAsAwaitingTrust() throws {
        let codexHome = try makeCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try installSpacesHooks(codexHome)
        let stale = try listedSpacesCommands(codexHome).mapValues { $0 + " # an older text" }
        try FakeCodexAppServer.trustTables(stale).write(to: configFile(codexHome), atomically: true, encoding: .utf8)

        #expect(status(codexHome, fake: FakeCodexAppServer()).installState == .awaitingTrust)
    }

    @Test func entriesCodexTrustsReadAsCurrent() throws {
        let codexHome = try makeCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try installSpacesHooks(codexHome)
        try FakeCodexAppServer.trustTables(try listedSpacesCommands(codexHome)).write(to: configFile(codexHome), atomically: true, encoding: .utf8)

        #expect(status(codexHome, fake: FakeCodexAppServer()) == .init(installState: .current, untrustedEntries: []))
    }

    /// A switched-off entry outranks untrusted ones: it stays off however the trust goes.
    @Test func aSwitchedOffEntryReadsAsSwitchedOffBesideUntrustedOnes() throws {
        let codexHome = try makeCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try installSpacesHooks(codexHome)
        let keyPath = FakeCodexAppServer.hooksFileKeyPath(codexHome: codexHome)
        try "[hooks.state.\"\(keyPath):stop:0:0\"]\nenabled = false\n".write(to: configFile(codexHome), atomically: true, encoding: .utf8)

        #expect(status(codexHome, fake: FakeCodexAppServer()) == .init(installState: .disabledByAgent, untrustedEntries: []))
    }

    /// Entries naming another `spaces` (another profile's CLI, or one that moved) are not what this
    /// device writes, so there is nothing to trust until an update rewrites them.
    @Test func entriesNamingAnotherSpacesCLIReadAsOutdated() throws {
        let codexHome = try makeCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try installSpacesHooks(codexHome, spacesPath: "/Users/someone/.spaces/bin/spaces")

        #expect(status(codexHome, fake: FakeCodexAppServer()) == .init(installState: .outdated, untrustedEntries: []))
    }

    /// A Codex that cannot answer reads as awaiting trust over every entry this device writes: the
    /// state whose action asks Codex again and shows its reason, rather than a green row over hooks
    /// Codex may be skipping.
    @Test(arguments: [
        FakeCodexAppServer.Behavior.failsToLaunch("No such file or directory"), .exitsImmediately(status: 2, detail: "unrecognized subcommand"),
        .neverAnswers, .rejects(method: "hooks/list", message: "unknown variant `hooks/list`"),
    ]) func aCodexThatCannotAnswerReadsAsAwaitingTrust(_ behavior: FakeCodexAppServer.Behavior) throws {
        let codexHome = try makeCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try installSpacesHooks(codexHome)

        #expect(
            status(codexHome, fake: FakeCodexAppServer(behavior: behavior))
                == .init(installState: .awaitingTrust, untrustedEntries: expectedEntries()))
    }

    // MARK: - The exchange

    /// One status check is one short session: the handshake, then a single listing, with whatever Codex
    /// announces in between read past.
    @Test func aStatusCheckIsOneSessionWithOneListing() throws {
        let codexHome = try makeCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try installSpacesHooks(codexHome)
        let fake = FakeCodexAppServer()

        _ = status(codexHome, fake: fake)

        #expect(fake.launchCount == 1)
        #expect(fake.methods == ["initialize", "initialized", "hooks/list"])
    }

    /// A trust lists, writes only what needs writing, and lists again to confirm Codex took it.
    @Test func trustWritesOnceAndConfirmsByListingAgain() throws {
        let codexHome = try makeCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try installSpacesHooks(codexHome)
        let fake = FakeCodexAppServer()

        try trust(codexHome, fake: fake)

        #expect(fake.methods == ["initialize", "initialized", "hooks/list", "config/batchWrite", "hooks/list"])
    }

    @Test func trustingWhatCodexAlreadyTrustsWritesNothing() throws {
        let codexHome = try makeCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try installSpacesHooks(codexHome)
        try FakeCodexAppServer.trustTables(try listedSpacesCommands(codexHome)).write(to: configFile(codexHome), atomically: true, encoding: .utf8)
        let fake = FakeCodexAppServer()

        try trust(codexHome, fake: fake)

        #expect(!fake.methods.contains("config/batchWrite"))
    }

    // MARK: - Failing with Codex's reason

    @Test func trustFailsWithCodexsOwnReason() throws {
        let codexHome = try makeCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try installSpacesHooks(codexHome)
        let cases: [(FakeCodexAppServer.Behavior, AgentHookCodexAppServer.Failure)] = [
            (.failsToLaunch("No such file or directory"), .launch("No such file or directory")),
            (
                .exitsImmediately(status: 2, detail: "error: unrecognized subcommand 'app-server'"),
                .exited(status: 2, detail: "error: unrecognized subcommand 'app-server'")
            ), (.neverAnswers, .timedOut),
            (
                .rejects(method: "config/batchWrite", message: "config.toml is read-only"),
                .rejected(method: "config/batchWrite", message: "config.toml is read-only")
            ),
        ]
        for (behavior, failure) in cases { #expect(throws: failure) { try trust(codexHome, fake: FakeCodexAppServer(behavior: behavior)) } }
        #expect(!read(configFile(codexHome)).contains("trusted_hash"))
    }

    /// Codex accepting the write is not the same as Codex trusting the hooks; the listing after the
    /// write is what decides.
    @Test func trustFailsWhenCodexStillListsTheEntriesAsUntrusted() throws {
        let codexHome = try makeCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try installSpacesHooks(codexHome)

        #expect(throws: AgentHookCodexTrust.TrustError.notRecorded(count: CodingAgent.codex.jsonEventBindings.count)) {
            try trust(codexHome, fake: FakeCodexAppServer(behavior: .dropsTrustWrites))
        }
    }

    /// Hooks this device would not write are never trusted, not even the ones that do match: the file
    /// needs an update first, and trusting half of it would only be undone by that update.
    @Test func trustRefusesWhileSomeEventLacksThisDevicesEntry() throws {
        let codexHome = try makeCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try installSpacesHooks(codexHome, spacesPath: "/Users/someone/.spaces/bin/spaces")
        let fake = FakeCodexAppServer()

        #expect(throws: AgentHookCodexTrust.TrustError.entriesNotListed) { try trust(codexHome, fake: fake) }
        #expect(!fake.methods.contains("config/batchWrite"))
    }

    /// An unknown-method error lists every method the server has; the caption gets its first line, bounded.
    @Test func codexsReasonIsCutToOneBoundedLine() {
        let long = String(repeating: "x", count: 500)
        #expect(AgentHookCodexAppServer.summary("\n  unknown variant `hooks/list`  \nexpected one of ...") == "unknown variant `hooks/list`")
        #expect(AgentHookCodexAppServer.summary(long) == String(repeating: "x", count: 200) + "…")
    }

    // MARK: - Naming

    /// A codex home reached through a symlink is named by Codex under the directory the link points at.
    /// Matching entries by the path Spaces walked would find none of them and report the row out of date
    /// forever, so the match follows Codex's resolution.
    @Test func entriesOfAHomeReachedThroughASymlinkAreStillSpaces() throws {
        let enclosing = try makeCodexHome()
        defer { try? FileManager.default.removeItem(at: enclosing) }
        let resolved = enclosing.appendingPathComponent("resolved", isDirectory: true)
        let linked = enclosing.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: resolved)
        try installSpacesHooks(linked)
        let fake = FakeCodexAppServer()

        #expect(status(linked, fake: fake).installState == .awaitingTrust)
        try trust(linked, fake: fake)
        #expect(status(linked, fake: fake).installState == .current)
    }
}
