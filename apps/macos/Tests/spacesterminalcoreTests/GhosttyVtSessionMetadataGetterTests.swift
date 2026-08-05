import Foundation
import Testing
import ghosttyvtshim

/// The shim getters that expose a headless vt session's escape-sequence-set metadata: the title from
/// OSC 0/2 and the raw OSC 7 working-directory payload. These drive the real dynamic libghostty-vt,
/// so they also pin the contract the Linux headless core depends on — the values must be copied out
/// (the library's own pointers are borrowed and die on the next write) and an unset value must be
/// reported as absent rather than as an empty string.
@Suite struct GhosttyVtSessionMetadataGetterTests {
    private func makeSession() throws -> OpaquePointer { try #require(spaces_ghostty_vt_session_new(80, 24, 0, nil)) }

    private func write(_ session: OpaquePointer, _ text: String) {
        let data = Data(text.utf8)
        let ok = data.withUnsafeBytes { spaces_ghostty_vt_session_write(session, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        #expect(ok)
    }

    private func read(_ getter: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<Int>) -> Bool) -> String? {
        var pointer: UnsafeMutablePointer<CChar>?
        var length = 0
        guard getter(&pointer, &length), let pointer, length > 0 else { return nil }
        defer { spaces_ghostty_vt_free_buffer(pointer) }
        return pointer.withMemoryRebound(to: UInt8.self, capacity: length) {
            String(decoding: UnsafeBufferPointer(start: $0, count: length), as: UTF8.self)
        }
    }

    private func title(_ session: OpaquePointer) -> String? { read { spaces_ghostty_vt_session_title(session, $0, $1) } }

    private func pwd(_ session: OpaquePointer) -> String? { read { spaces_ghostty_vt_session_pwd(session, $0, $1) } }

    @Test func reportsNoTitleOrWorkingDirectoryBeforeAnyEscapeSequence() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }
        #expect(title(session) == nil)
        #expect(pwd(session) == nil)
    }

    @Test func readsTitleSetByOSC2() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }
        write(session, "\u{1B}]2;first title\u{07}")
        #expect(title(session) == "first title")
    }

    @Test func readsTitleSetByOSC0() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }
        write(session, "\u{1B}]0;icon and window\u{07}")
        #expect(title(session) == "icon and window")
    }

    /// The copy must survive the write that invalidates the library's borrowed pointer, and the
    /// latest title must win.
    @Test func titleCopySurvivesLaterWritesAndTracksTheLatestValue() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }
        write(session, "\u{1B}]2;first title\u{07}")
        let first = title(session)
        write(session, "\u{1B}]2;second title\u{07}hello world")
        #expect(first == "first title")
        #expect(title(session) == "second title")
    }

    @Test func reportsAnEmptyTitlePayloadAsAbsent() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }
        write(session, "\u{1B}]2;something\u{07}")
        #expect(title(session) == "something")
        write(session, "\u{1B}]2;\u{07}")
        #expect(title(session) == nil)
    }

    /// OSC 7 is stored verbatim — the VT layer never parses the URI — which is why the Swift side
    /// owns the decode.
    @Test func readsWorkingDirectoryAsTheRawOSC7Payload() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }
        write(session, "\u{1B}]7;file://localhost/home/dev/project\u{07}")
        #expect(pwd(session) == "file://localhost/home/dev/project")
    }
}
