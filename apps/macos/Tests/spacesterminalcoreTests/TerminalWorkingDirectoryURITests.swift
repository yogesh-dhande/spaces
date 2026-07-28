import Foundation
import Testing

@testable import spacesterminalcore

/// The OSC 7 decode rules a caller must apply to the raw payload libghostty-vt stores, matching
/// what Ghostty's full-surface path does before a working directory reaches the app.
@Suite struct TerminalWorkingDirectoryURITests {
    private func decoded(_ payload: String, host: String? = "build-host") -> String? {
        TerminalWorkingDirectoryURI.decodedPath(fromOSC7: payload, localHostName: host)
    }

    @Test func decodesFileURIWithLocalhostAuthority() { #expect(decoded("file://localhost/home/dev/project") == "/home/dev/project") }

    /// Ghostty rejects a hostless URI (its `isLocal("")` is false), so the macOS core never accepts
    /// one; accepting it here would diverge the cores and let a remote program skip the host check.
    @Test func rejectsFileURIWithEmptyAuthority() { #expect(decoded("file:///home/dev/project") == nil) }

    @Test func decodesFileURIWithThisMachinesHostname() {
        #expect(decoded("file://build-host/home/dev/project", host: "build-host") == "/home/dev/project")
    }

    @Test func percentUnescapesFileURIPaths() {
        #expect(decoded("file://localhost/home/dev/my%20project/caf%C3%A9") == "/home/dev/my project/café")
    }

    @Test func keepsKittyShellCwdPathsUnescaped() {
        // kitty-shell-cwd carries an already-unencoded path, so a literal percent stays literal.
        #expect(decoded("kitty-shell-cwd://localhost/home/dev/100%25") == "/home/dev/100%25")
    }

    @Test func ignoresNonLocalHost() { #expect(decoded("file://someone-elses-box/home/dev/project") == nil) }

    @Test func ignoresUnsupportedScheme() {
        #expect(decoded("http://localhost/home/dev/project") == nil)
        #expect(decoded("/home/dev/project") == nil)
    }

    @Test func ignoresPayloadWithoutAPath() {
        #expect(decoded("file://localhost") == nil)
        #expect(decoded("") == nil)
    }

    @Test func ignoresMalformedPercentEscape() { #expect(decoded("file://localhost/home/dev/%ZZ") == nil) }
}
