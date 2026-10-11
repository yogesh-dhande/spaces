import Foundation
import Testing

@testable import spacesdevicecore

/// The open policy for hyperlinks a program printed (OSC 8): which targets open, which ask first and
/// which are refused, before any client routing sees them.
@Suite struct SpacesUntrustedTerminalLinkTests {
    private func decision(_ string: String, at location: SpacesUntrustedTerminalLink.FileLocation = .thisDevice)
        -> SpacesUntrustedTerminalLink.Decision
    { SpacesUntrustedTerminalLink(string).decision(fileLocation: location) }

    // MARK: - Web and mail

    @Test func webLinksWithAHostOpenDirectly() {
        #expect(decision("https://example.com/docs") == .allow(URL(string: "https://example.com/docs")!))
        #expect(decision("HTTP://example.com") == .allow(URL(string: "HTTP://example.com")!))
        #expect(decision("http://localhost:3000/dashboard") == .allow(URL(string: "http://localhost:3000/dashboard")!))
    }

    @Test func webLinksWithoutAHostAreBlocked() {
        #expect(decision("https:relative") == .deny(.invalidWebURL))
        #expect(decision("https://") == .deny(.invalidWebURL))
    }

    @Test func mailLinksWithAnAddressOpenDirectly() {
        #expect(decision("mailto:person@example.com") == .allow(URL(string: "mailto:person@example.com")!))
        #expect(decision("mailto:person@example.com?subject=Hi") == .allow(URL(string: "mailto:person@example.com?subject=Hi")!))
    }

    @Test func aMailLinkWithoutAnAddressIsBlocked() { #expect(decision("mailto:") == .deny(.malformedURL)) }

    // MARK: - Other schemes

    @Test func otherSchemesAskFirst() {
        #expect(decision("slack://open?team=T1") == .confirm(URL(string: "slack://open?team=T1")!))
        #expect(decision("ssh://host") == .confirm(URL(string: "ssh://host")!))
    }

    @Test func aSpacesTerminalDeepLinkOpensWithoutAsking() {
        #expect(decision("spaces://terminal/session-1") == .allow(URL(string: "spaces://terminal/session-1")!))
        #expect(decision("spaces://terminal/session-1?device=device-9") == .allow(URL(string: "spaces://terminal/session-1?device=device-9")!))
    }

    @Test func otherSpacesLinksAskFirstLikeAnyCustomScheme() {
        #expect(decision("spaces://pair?code=abc") == .confirm(URL(string: "spaces://pair?code=abc")!))
        #expect(decision("spaces://terminal") == .confirm(URL(string: "spaces://terminal")!))
    }

    // MARK: - Malformed and unsafe targets

    @Test func anEmptyTargetIsBlocked() { #expect(decision("") == .deny(.malformedURL)) }

    @Test func aTargetWithoutASchemeIsBlockedSoNoLayerReadsItAsAPath() {
        #expect(decision("/etc/passwd") == .deny(.malformedURL))
        #expect(decision("~/notes.md") == .deny(.malformedURL))
        #expect(decision("docs/readme.md") == .deny(.malformedURL))
    }

    @Test func controlAndBidirectionalCharactersAreBlocked() {
        #expect(decision("https://example.com/\u{0A}evil") == .deny(.unsafeCharacters))
        #expect(decision("https://example.com/\u{202E}gnp.exe") == .deny(.unsafeCharacters))
        #expect(decision("https://example.com/\u{200B}") == .deny(.unsafeCharacters))
        #expect(decision("https://example.com/\u{2028}") == .deny(.unsafeCharacters))
        #expect(decision("https://example.com/\u{FEFF}") == .deny(.unsafeCharacters))
        #expect(decision("https://example.com/\u{85}") == .deny(.unsafeCharacters))
    }

    private func display(_ string: String, at location: SpacesUntrustedTerminalLink.FileLocation) -> String {
        SpacesUntrustedTerminalLink(string).displayString(fileLocation: location)
    }

    @Test(arguments: [SpacesUntrustedTerminalLink.FileLocation.thisDevice, .anotherDevice]) func displayStringShowsUnsafeCharactersAsTextOnOneLine(
        location: SpacesUntrustedTerminalLink.FileLocation
    ) {
        let display = display("https://example.com/a\u{202E}b\nc", at: location)
        #expect(display.contains("\\u{202E}"))
        #expect(display.contains("\\u{A}"))
        #expect(!display.unicodeScalars.contains("\u{202E}"))
        #expect(!display.contains("\n"))
    }

    @Test(arguments: [SpacesUntrustedTerminalLink.FileLocation.thisDevice, .anotherDevice]) func displayStringKeepsWebTargetsByteForByte(
        location: SpacesUntrustedTerminalLink.FileLocation
    ) { #expect(display("https://example.com//a/../b", at: location) == "https://example.com//a/../b") }

    /// A relative path opens relative to the session's directory, which the client cannot know, so it is
    /// shown as written rather than resolved against the client's own working directory.
    @Test(arguments: [SpacesUntrustedTerminalLink.FileLocation.thisDevice, .anotherDevice]) func displayStringShowsASchemelessTargetAsWritten(
        location: SpacesUntrustedTerminalLink.FileLocation
    ) {
        #expect(display("src/app/main.swift", at: location) == "src/app/main.swift")
        #expect(display("../a//b.txt", at: location) == "../a//b.txt")
    }

    @Test(arguments: [SpacesUntrustedTerminalLink.FileLocation.thisDevice, .anotherDevice])
    func displayStringRemovesDotSegmentsAndRepeatedSeparatorsFromAFileURL(location: SpacesUntrustedTerminalLink.FileLocation) {
        #expect(display("file:///tmp/a/../b//./c.txt", at: location).hasSuffix("/tmp/b/c.txt"))
    }

    @Test func displayStringOfAFileURLOnAnotherDeviceIsPurelyLexical() {
        #expect(display("file:///tmp/a/../b//./c.txt", at: .anotherDevice) == "/tmp/b/c.txt")
        #expect(display("file:///../../x", at: .anotherDevice) == "/x")
    }

    @Test func displayStringResolvesSymlinksOnlyOnThisDevice() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = directory.appendingPathComponent("real.txt")
        try Data("x".utf8).write(to: real)
        let alias = directory.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)

        #expect(display(alias.absoluteString, at: .thisDevice).hasSuffix("/real.txt"))
        #expect(display(alias.absoluteString, at: .anotherDevice).hasSuffix("/alias.txt"))
    }

    // MARK: - File links

    @Test func fileLinksOnAnotherDeviceOnlyNeedTheRightShape() {
        #expect(decision("file:///tmp/report.png", at: .anotherDevice) == .allow(URL(string: "file:///tmp/report.png")!))
        #expect(decision("file://localhost/tmp/report.png", at: .anotherDevice) == .allow(URL(string: "file://localhost/tmp/report.png")!))
        #expect(decision("file:///tmp/report.png?x=1", at: .anotherDevice) == .deny(.malformedURL))
        #expect(decision("file:///tmp/report.png#top", at: .anotherDevice) == .deny(.malformedURL))
        #expect(decision("file://build-host/tmp/report.png", at: .anotherDevice) == .deny(.malformedURL))
    }

    @Test func fileLinksOnThisDeviceNameAnExistingRegularFileOrDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.txt")
        try Data("hi".utf8).write(to: file)
        let subdirectory = directory.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)

        #expect(decision(file.absoluteString) == .allow(file.standardizedFileURL.resolvingSymlinksInPath()))
        #expect(decision("file://localhost\(file.path)") == .allow(file.standardizedFileURL.resolvingSymlinksInPath()))
        #expect(decision(subdirectory.absoluteString) == .allow(subdirectory.standardizedFileURL.resolvingSymlinksInPath()))
        #expect(decision(directory.appendingPathComponent("missing.txt").absoluteString) == .deny(.inaccessibleFile))
    }

    @Test func fileLinksWithAQueryFragmentOrNamedHostAreBlockedOnThisDevice() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.txt")
        try Data("hi".utf8).write(to: file)

        #expect(decision(file.absoluteString + "?x=1") == .deny(.malformedURL))
        #expect(decision(file.absoluteString + "#frag") == .deny(.malformedURL))
        #expect(decision("file://build-host\(file.path)") == .deny(.malformedURL))
    }

    @Test func executableFilesAndExecutableContainersAreBlockedOnThisDevice() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = directory.appendingPathComponent("run.txt")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        #expect(decision(script.absoluteString) == .deny(.unsafeFile))

        let command = directory.appendingPathComponent("go.command")
        try Data("echo".utf8).write(to: command)
        #expect(decision(command.absoluteString) == .deny(.unsafeFile))

        let bundle = directory.appendingPathComponent("Tool.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        #expect(decision(bundle.absoluteString) == .deny(.unsafeFile))
    }

    /// The policy classifies what the link resolves to, not what it is called.
    @Test func aSymlinkToAnExecutableIsClassifiedByItsTarget() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("run.sh")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let link = directory.appendingPathComponent("harmless.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: script)

        #expect(decision(link.absoluteString) == .deny(.unsafeFile))
    }

    @Test func escapingUnsafeCharactersWritesThemAsScalars() {
        #expect(SpacesUntrustedTerminalLink.escapingUnsafeCharacters("a\u{202E}gpj.exe") == "a\\u{202E}gpj.exe")
        #expect(SpacesUntrustedTerminalLink.escapingUnsafeCharacters("person\nevil@example.com") == "person\\u{A}evil@example.com")
        #expect(SpacesUntrustedTerminalLink.escapingUnsafeCharacters("src/app/main.swift") == "src/app/main.swift")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("untrusted-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
