import Foundation
import Testing
import ghosttyvtshim

/// The shim's terminal event sink: the bell, title, pwd, clipboard, and pty-response callbacks
/// libghostty-vt invokes while it parses a write, accumulated per turn and drained by the caller.
/// These drive the real dynamic libghostty-vt, so they pin the contract the headless session core
/// depends on — that events are opt-in, that a drain empties the sink, and that borrowed payloads are
/// copied out before the write that produced them returns.
@Suite struct GhosttyVtSessionEventSinkTests {
    /// A drained turn's events as Swift values, so the C record's buffers are released immediately.
    private struct Events {
        var titleChanged = false
        var pwdChanged = false
        var bellCount: UInt32 = 0
        var clipboardText: String?
        var clipboardByteCount = 0
        var clipboardCleared = false
        var clipboardDropped = false
        var ptyResponse = ""
    }

    private func makeSession(events: Bool = true) throws -> OpaquePointer {
        let session = try #require(spaces_ghostty_vt_session_new(80, 24, 0, nil))
        if events { #expect(spaces_ghostty_vt_session_enable_events(session)) }
        return session
    }

    private func write(_ session: OpaquePointer, _ text: String) {
        let data = Data(text.utf8)
        let ok = data.withUnsafeBytes { spaces_ghostty_vt_session_write(session, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        #expect(ok)
    }

    private func drain(_ session: OpaquePointer) -> Events {
        var raw = SpacesGhosttyVtSessionEvents()
        spaces_ghostty_vt_session_drain_events(session, &raw)
        defer { spaces_ghostty_vt_session_events_free(&raw) }
        var events = Events(
            titleChanged: raw.title_changed, pwdChanged: raw.pwd_changed, bellCount: raw.bell_count, clipboardByteCount: raw.clipboard_len,
            clipboardCleared: raw.clipboard_cleared, clipboardDropped: raw.clipboard_dropped)
        if let text = raw.clipboard_text {
            events.clipboardText = text.withMemoryRebound(to: UInt8.self, capacity: raw.clipboard_len) {
                String(decoding: UnsafeBufferPointer(start: $0, count: raw.clipboard_len), as: UTF8.self)
            }
        }
        if let response = raw.pty_response, raw.pty_response_len > 0 {
            events.ptyResponse = response.withMemoryRebound(to: UInt8.self, capacity: raw.pty_response_len) {
                String(decoding: UnsafeBufferPointer(start: $0, count: raw.pty_response_len), as: UTF8.self)
            }
        }
        return events
    }

    private func osc52(_ payload: String) -> String { "\u{1B}]52;c;\(payload)\u{07}" }

    @Test func bellsAreCountedAndTheDrainEmptiesTheSink() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }

        write(session, "alert\u{07}and again\u{07}")
        #expect(drain(session).bellCount == 2)
        #expect(drain(session).bellCount == 0)

        write(session, "\u{07}")
        #expect(drain(session).bellCount == 1)
    }

    /// The title event carries no value — the caller reads it back — so what the event contributes is
    /// the fact that the program said something about the title at all.
    @Test func titleChangesRaiseAnEvent() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }

        write(session, "\u{1B}]2;live title\u{07}")
        let events = drain(session)
        #expect(events.titleChanged)
        #expect(!events.pwdChanged)
        #expect(!drain(session).titleChanged)
    }

    /// The distinction the getters cannot express: an empty payload reads back exactly like a title
    /// that was never set, so only the event tells the caller that the program cleared it. Including
    /// on a session that never carried a title, which is the shape a rebuilt session sees.
    @Test func clearingTheTitleRaisesAnEventEvenWhenNoTitleWasSet() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }

        write(session, "\u{1B}]2;\u{07}")
        #expect(drain(session).titleChanged)

        write(session, "\u{1B}]2;something\u{07}")
        #expect(drain(session).titleChanged)
        write(session, "\u{1B}]2;\u{07}")
        #expect(drain(session).titleChanged)
    }

    @Test func workingDirectoryChangesAndClearsRaiseEvents() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }

        write(session, "\u{1B}]7;file://localhost/srv/work\u{07}")
        let reported = drain(session)
        #expect(reported.pwdChanged)
        #expect(!reported.titleChanged)

        write(session, "\u{1B}]7;\u{07}")
        #expect(drain(session).pwdChanged)
    }

    /// OSC 52 payloads are base64 in the wire protocol; the callback receives them already decoded.
    @Test func clipboardWritesArriveDecoded() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }

        write(session, osc52(Data("copied text".utf8).base64EncodedString()))
        let events = drain(session)
        #expect(events.clipboardText == "copied text")
        #expect(events.clipboardByteCount == 11)
        #expect(!events.clipboardCleared)
        #expect(!events.clipboardDropped)
        #expect(drain(session).clipboardText == nil)
    }

    /// Two writes in one turn are one clipboard value: the last one wins.
    @Test func theLastClipboardWriteOfATurnWins() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }

        write(session, osc52(Data("first".utf8).base64EncodedString()) + osc52(Data("second".utf8).base64EncodedString()))
        #expect(drain(session).clipboardText == "second")
    }

    /// An OSC 52 write with no payload asks for the clipboard to be emptied, which is distinct from
    /// never having written to it.
    @Test func anEmptyClipboardPayloadReportsAClear() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }

        write(session, osc52(Data("stale".utf8).base64EncodedString()))
        #expect(drain(session).clipboardText == "stale")

        write(session, osc52(""))
        let events = drain(session)
        #expect(events.clipboardCleared)
        #expect(events.clipboardText == nil)
    }

    /// A payload past the cap is refused outright rather than buffered, and the refusal is reported so
    /// the caller can tell it apart from a turn that carried no clipboard write.
    @Test func anOversizedClipboardPayloadIsDropped() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }

        let oversized = String(repeating: "a", count: Int(SPACES_GHOSTTY_VT_MAX_CLIPBOARD_BYTES) + 1024)
        write(session, osc52(Data(oversized.utf8).base64EncodedString()))
        let events = drain(session)
        #expect(events.clipboardDropped)
        #expect(events.clipboardText == nil)
    }

    /// Terminal queries are answered through the write-pty effect, in the order the terminal emitted
    /// the replies, so a program that asks several questions in one write can parse the answers.
    @Test func queryRepliesAccumulateInEmissionOrder() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }

        write(session, "\u{1B}[6n\u{1B}[?2026$p")
        let events = drain(session)
        #expect(events.ptyResponse.hasPrefix("\u{1B}[1;1R"))
        #expect(events.ptyResponse.contains("$y"))
        #expect(drain(session).ptyResponse.isEmpty)
    }

    /// Events are opt-in because a session that replays a transcript must not re-raise the bells and
    /// clipboard writes the recorded output once carried.
    @Test func aSessionWithoutEventsEnabledAccumulatesNothing() throws {
        let session = try makeSession(events: false)
        defer { spaces_ghostty_vt_session_free(session) }

        write(session, "\u{07}\u{1B}]2;replayed\u{07}\u{1B}]7;file://localhost/srv/replayed\u{07}" + osc52(Data("old".utf8).base64EncodedString()))
        write(session, "\u{1B}[6n")
        let events = drain(session)
        #expect(events.bellCount == 0)
        #expect(!events.titleChanged)
        #expect(!events.pwdChanged)
        #expect(events.clipboardText == nil)
        #expect(events.ptyResponse.isEmpty)
    }
}
