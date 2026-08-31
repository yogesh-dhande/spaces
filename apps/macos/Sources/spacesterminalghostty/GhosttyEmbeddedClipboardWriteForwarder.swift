#if canImport(AppKit) && canImport(GhosttyKit)
    import Foundation
    import GhosttyKit
    import spacesterminalcore

    /// Turns the daemon runtime's write-clipboard callback into a clipboard write for the session that
    /// produced it.
    ///
    /// The daemon deliberately does NOT write its own `NSPasteboard` here. Its host is not the machine
    /// the user is typing on — for a session served to a phone or to another Mac it is the wrong
    /// machine entirely — so the write is handed to the session host, which forwards it to the attached
    /// owner and drops it when nothing owns the session.
    enum GhosttyEmbeddedClipboardWriteForwarder {
        /// Matches `SPACES_GHOSTTY_VT_MAX_CLIPBOARD_BYTES` in the Linux vt shim, so both cores refuse the
        /// same runaway payload and a session behaves identically on either daemon. The generated Ghostty
        /// config's `clipboard-write-limit-bytes` carries this same value, so Ghostty itself refuses a
        /// larger OSC 5522 transaction before it ever reaches this forwarder.
        static let maximumClipboardWriteBytes = 1 * 1024 * 1024

        static func forward(
            userdata: UnsafeMutableRawPointer?, location: ghostty_clipboard_e, content: UnsafePointer<ghostty_clipboard_content_s>?, count: Int
        ) {
            // Spaces carries only the system clipboard; the selection clipboard has no counterpart on
            // a client device. The embedded write callback carries no result back to Ghostty, so a
            // Kitty clipboard (OSC 5522) write dropped here (selection location, or no `text/plain`
            // representation) still reads to the program as acknowledged. Accepted: such writes have
            // nothing Spaces could deliver, and reporting failure would need a fork-side ABI change.
            guard location == GHOSTTY_CLIPBOARD_STANDARD else { return }
            // Mirror surfaces set no `GhosttyEmbeddedSurfaceUserData`, so a null userdata means this is
            // not a daemon session surface and there is no session to attribute the write to.
            guard let userdata else { return }
            guard let text = plainText(content: content, count: count) else { return }
            let surfaceUserData = Unmanaged<GhosttyEmbeddedSurfaceUserData>.fromOpaque(userdata).takeUnretainedValue()
            guard !surfaceUserData.isReplayingHistoricalOutput else { return }
            Task { @TerminalEngineActor in surfaceUserData.handleClipboardWrite(text) }
        }

        /// The text this write asks the owner to hold: the first `text/plain` representation, or the
        /// empty string when the write carries none — an OSC 52 clear, which the owner applies by
        /// emptying its pasteboard. `nil` means the write is refused (no usable representation, or over
        /// the cap).
        private static func plainText(content: UnsafePointer<ghostty_clipboard_content_s>?, count: Int) -> String? {
            guard let content, count > 0 else { return "" }
            guard let text = GhosttyClipboardBridge.preferredPlainText(from: UnsafeBufferPointer(start: content, count: count)) else { return nil }
            guard text.utf8.count <= maximumClipboardWriteBytes else { return nil }
            return text
        }
    }
#endif
