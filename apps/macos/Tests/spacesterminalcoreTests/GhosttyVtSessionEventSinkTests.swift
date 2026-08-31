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

    /// One Kitty clipboard protocol (OSC 5522) packet: `ESC ] 5522 ; <metadata> [; <base64 payload>] BEL`.
    /// A nil payload omits the payload section entirely (used by the commit packet, which carries none).
    private func kitty5522(_ metadata: String, payload: String? = nil) -> String {
        guard let payload else { return "\u{1B}]5522;\(metadata)\u{07}" }
        return "\u{1B}]5522;\(metadata);\(payload)\u{07}"
    }

    /// A complete Kitty clipboard write transaction targeting the standard clipboard: the `type=write`
    /// packet that opens it, one `type=wdata` packet carrying the base64-encoded `text/plain` payload,
    /// and the empty-mime `type=wdata` packet that commits it. Wire format per
    /// src/terminal/kitty/clipboard_write.zig and osc/parsers/kitty_clipboard_protocol.zig.
    private func kittyClipboardWrite(_ text: String) -> String {
        let mime = Data("text/plain".utf8).base64EncodedString()
        let payload = Data(text.utf8).base64EncodedString()
        return kitty5522("type=write") + kitty5522("type=wdata:mime=\(mime)", payload: payload) + kitty5522("type=wdata")
    }

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

    /// The Kitty clipboard protocol (OSC 5522) answers every write with a status packet on the same
    /// write-pty path as other query replies, distinct from OSC 52 which has no acknowledgement at all.
    /// A committed write both raises the same clipboardText event OSC 52 does and reports success
    /// (status=DONE) to the writing program, rather than the EPERM a denied write would send.
    @Test func kittyClipboardWriteIsAcknowledged() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }

        write(session, kittyClipboardWrite("kitty clipboard text"))
        let events = drain(session)
        #expect(events.clipboardText == "kitty clipboard text")
        #expect(!events.clipboardDropped)
        #expect(events.ptyResponse == "\u{1B}]5522;type=write:status=DONE\u{07}")
    }

    /// A chosen text/plain representation whose payload is itself empty is a clear, not a zero-length
    /// write: the transaction still commits (status=DONE) but the shim must record clipboard_cleared
    /// rather than clipboard_len == 0, matching the macOS forwarder's treatment of an empty write as a
    /// clear (GhosttyEmbeddedClipboardWriteForwarder).
    @Test func aZeroLengthKittyTextWriteReportsAClear() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }

        write(session, kittyClipboardWrite("stale"))
        #expect(drain(session).clipboardText == "stale")

        write(session, kittyClipboardWrite(""))
        let events = drain(session)
        #expect(events.clipboardCleared)
        #expect(events.clipboardText == nil)
        #expect(events.ptyResponse == "\u{1B}]5522;type=write:status=DONE\u{07}")
    }

    /// GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE_MAX_BYTES is set to SPACES_GHOSTTY_VT_MAX_CLIPBOARD_BYTES at
    /// session creation, so an oversized 5522 transaction is rejected by libghostty-vt's own transaction
    /// buffer (EFBIG) before the payload ever reaches the shim's clipboard_write callback: no clipboardText
    /// event, no clipboardDropped either, since the callback that sets it is never invoked.
    @Test func oversizedKittyClipboardWriteIsRejectedBeforeBuffering() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }

        let oversized = String(repeating: "a", count: Int(SPACES_GHOSTTY_VT_MAX_CLIPBOARD_BYTES) + 3)
        let mime = Data("text/plain".utf8).base64EncodedString()
        let payload = Data(oversized.utf8).base64EncodedString()
        write(session, kitty5522("type=write") + kitty5522("type=wdata:mime=\(mime)", payload: payload))
        let events = drain(session)
        #expect(events.clipboardText == nil)
        #expect(events.ptyResponse == "\u{1B}]5522;type=write:status=EFBIG\u{07}")
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

    /// A headless session deliberately advertises Ghostty's conservative VT220-compatible defaults:
    /// ANSI color, no invented firmware version, and no per-installation unit identifier.
    @Test func deviceAttributeQueriesReceiveDeclaredReplies() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }

        write(session, "\u{1B}[c\u{1B}[>c\u{1B}[=c")
        #expect(drain(session).ptyResponse == "\u{1B}[?62;22c\u{1B}[>1;0;0c\u{1B}P!|00000000\u{1B}\\")
    }

    /// The daemon has no rendered pixel geometry, so one cell is one synthetic pixel. Character
    /// dimensions remain exact, and pixel queries stay internally consistent with that convention.
    @Test func sizeQueriesReceiveCellGranularHeadlessGeometry() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }

        write(session, "\u{1B}[14t\u{1B}[16t\u{1B}[18t")
        #expect(drain(session).ptyResponse == "\u{1B}[4;24;80t\u{1B}[6;1;1t\u{1B}[8;24;80t")

        #expect(spaces_ghostty_vt_session_resize(session, 100, 40))
        write(session, "\u{1B}[14t\u{1B}[18t")
        #expect(drain(session).ptyResponse == "\u{1B}[4;40;100t\u{1B}[8;40;100t")
    }

    /// A live session starts in the daemon's dark appearance, then reports the appearance carried by
    /// the latest theme after an attaching client rethemes it.
    @Test func colorSchemeQueryFollowsTheLiveAppearance() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }

        write(session, "\u{1B}[?996n")
        #expect(drain(session).ptyResponse == "\u{1B}[?997;1n")

        var lightTheme = SpacesGhosttyVtTheme()
        lightTheme.is_dark = false
        #expect(spaces_ghostty_vt_session_set_theme(session, &lightTheme))
        write(session, "\u{1B}[?996n")
        #expect(drain(session).ptyResponse == "\u{1B}[?997;2n")
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
