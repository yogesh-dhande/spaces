#if canImport(AppKit) && canImport(GhosttyKit)
    import AppKit
    import Foundation
    import GhosttyKit
    import spacesterminalcore

    enum GhosttyClipboardBridge {
        /// Answers a clipboard read request synchronously against `NSPasteboard.general`. Spaces only
        /// ever serves plain text, so `mimes` matters only to decide whether "text/plain" was requested;
        /// `list` only controls whether the available-mimes listing is populated. Spaces has one system
        /// clipboard, so only `GHOSTTY_CLIPBOARD_STANDARD` is served; a primary/selection read is
        /// reported unsupported, which tells Ghostty to free the request state itself.
        ///
        /// A daemon surface's read (OSC 52 `?` or a Kitty OSC 5522 read) is served from the clipboard of
        /// the Mac hosting the session, whichever device owns the session; Spaces has no owner-directed
        /// read path (writes are forwarded to the owner by `GhosttyEmbeddedClipboardWriteForwarder`,
        /// reads are not), and a program running on that Mac could read the same clipboard directly, so
        /// this is not a privacy boundary.
        static func readClipboard(
            userdata: UnsafeMutableRawPointer?,
            location: ghostty_clipboard_e,
            state: UnsafeMutableRawPointer?,
            mimes: UnsafePointer<UnsafePointer<CChar>?>?,
            mimesCount: Int,
            list: Bool,
            pasteboard: NSPasteboard = .general
        ) -> ghostty_clipboard_read_result_e {
            // Mirror surfaces set no `GhosttyEmbeddedSurfaceUserData` (they parse no VT stream, so they
            // never originate a clipboard request; paste on a mirror goes through `onSendText`, not
            // Ghostty's paste binding). Returning UNSUPPORTED here -- rather than STARTED, which would
            // promise a completion call that never comes -- matches the contract: any result other than
            // STARTED means `state` is Ghostty's to free immediately, and this code must never touch it
            // again.
            guard userdata != nil else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }

            // Spaces serves only the standard clipboard; a Kitty OSC 5522 read with loc=primary (or any
            // other selection-clipboard read) has no backing store here.
            guard location == GHOSTTY_CLIPBOARD_STANDARD else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }

            var wantsPlainText = false
            if let mimes {
                for i in 0..<mimesCount {
                    guard let ptr = mimes[i] else { continue }
                    if String(cString: ptr) == "text/plain" {
                        wantsPlainText = true
                        break
                    }
                }
            }

            // A listing request (mimesCount == 0, list == true, e.g. Kitty paste-event mode probing for
            // MIME types) must inspect metadata only, never load the clipboard payload. `types` reflects
            // an item's declared UTIs without invoking its data provider, so it is safe to consult
            // unconditionally; the payload itself is loaded only when `wantsPlainText` actually asks for it.
            let hasPlainTextType = pasteboard.types?.contains(.string) == true
            let text: String? = wantsPlainText ? pasteboard.string(forType: .string) : nil

            // Under the length-delimited ABI a zero-byte text/plain payload is a valid representation, so
            // an empty (but present) string is served, not treated as absent -- only a genuinely missing
            // string type (`text == nil`) counts as no plain text.
            var contents: [(mime: String, data: Data)] = []
            if wantsPlainText, let text {
                contents.append(("text/plain", Data(text.utf8)))
            }
            let available: [String] = (list && hasPlainTextType) ? ["text/plain"] : []

            if contents.isEmpty && !list {
                return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
            }

            completeClipboardRequest(userdata: userdata, contents: contents, available: available, state: state, confirmed: false, remember: false)
            return GHOSTTY_CLIPBOARD_READ_STARTED
        }

        /// Spaces auto-approves every clipboard confirmation with no UI prompt: a program's OSC 52 /
        /// Kitty clipboard read or write inside a session is granted silently, matching the silent
        /// OSC 52 write behavior documented in docs/spec.md.
        static func confirmReadClipboard(
            userdata: UnsafeMutableRawPointer?,
            confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
            state: UnsafeMutableRawPointer?
        ) {
            // A null userdata (a mirror surface) can never reach this callback: it never originates a
            // clipboard request in the first place (see readClipboard above), so there is nothing to
            // confirm or deny here.
            guard let userdata else { return }
            guard let confirm else { return }
            let c = confirm.pointee

            // `confirm`'s contents/available are borrowed for the duration of this call only, so copy
            // them into Swift values before hopping to the engine actor.
            var contents: [(mime: String, data: Data)] = []
            if let raw = c.contents {
                for i in 0..<c.contents_len {
                    let item = raw[i]
                    guard let mimePointer = item.mime else { continue }
                    let data: Data
                    if let dataPointer = item.data, item.len > 0 {
                        data = Data(bytes: dataPointer, count: Int(item.len))
                    } else {
                        data = Data()
                    }
                    contents.append((mime: String(cString: mimePointer), data: data))
                }
            }
            var available: [String] = []
            if let raw = c.available {
                for i in 0..<c.available_len {
                    guard let ptr = raw[i] else { continue }
                    available.append(String(cString: ptr))
                }
            }

            completeClipboardRequest(userdata: userdata, contents: contents, available: available, state: state, confirmed: true, remember: false)
        }

        static func writeClipboard(content: UnsafePointer<ghostty_clipboard_content_s>?, len: UInt) {
            guard let content, len > 0 else { return }
            let buffer = UnsafeBufferPointer(start: content, count: Int(len))
            guard let text = preferredPlainText(from: buffer) else { return }
            writePlainText(text, to: .general)
        }

        /// Replaces a pasteboard's contents with `text`. Empty text clears it and writes nothing, which
        /// is how an OSC 52 clear reaches the owner's machine.
        static func writePlainText(_ text: String, to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            guard !text.isEmpty else { return }
            pasteboard.setString(text, forType: .string)
        }

        static func copySelection(from surface: ghostty_surface_t?) -> Bool {
            guard let surface, ghostty_surface_has_selection(surface) else { return false }
            var text = ghostty_text_s()
            guard ghostty_surface_read_selection(surface, &text) else { return false }
            defer { ghostty_surface_free_text(surface, &text) }
            guard let pointer = text.text, text.text_len > 0 else { return false }
            let buffer = UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: Int(text.text_len))
            guard let value = String(bytes: buffer, encoding: .utf8), !value.isEmpty else { return false }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            return true
        }

        /// `data` is binary-safe and length-delimited (not necessarily NUL-terminated), so this decodes
        /// exactly `len` bytes rather than scanning for a terminator.
        static func preferredPlainText(from content: UnsafeBufferPointer<ghostty_clipboard_content_s>) -> String? {
            for item in content {
                guard let mime = item.mime.map(String.init(cString:)), mime.hasPrefix("text/plain") else { continue }
                return String(decoding: UnsafeRawBufferPointer(start: item.data, count: Int(item.len)), as: UTF8.self)
            }
            return nil
        }

        private static func completeClipboardRequest(
            userdata: UnsafeMutableRawPointer?,
            contents: [(mime: String, data: Data)],
            available: [String],
            state: UnsafeMutableRawPointer?,
            confirmed: Bool,
            remember: Bool
        ) {
            guard let userdata else { return }
            // The surface userdata is the daemon's engine-actor-isolated `GhosttyEmbeddedSurfaceUserData`
            // (mirror surfaces set none, so this only ever runs for daemon surfaces -- the guard above
            // early-returns for the null mirror userdata). Hop to the engine actor to read the surface,
            // preserving the pre-existing "complete on a later turn" pattern.
            let surfaceUserData = Unmanaged<GhosttyEmbeddedSurfaceUserData>.fromOpaque(userdata).takeUnretainedValue()
            let stateAddress = state.map { UInt(bitPattern: $0) }
            Task { @TerminalEngineActor in
                // If the surface vanished before this turn lands, the request is left uncompleted. This
                // was already true before this ABI port (Ghostty owns tearing down `state` on its own in
                // that case) and only happens during teardown.
                guard let surface = surfaceUserData.surface() else { return }
                let statePointer = stateAddress.flatMap(UnsafeMutableRawPointer.init(bitPattern:))
                sendClipboardCompletion(surface: surface, contents: contents, available: available, state: statePointer, confirmed: confirmed, remember: remember)
            }
        }

        /// Builds the C completion payload from Swift values and calls
        /// `ghostty_surface_complete_clipboard_request`. `contents`/`available` are copied into
        /// C-owned memory (via `strdup`/`allocate`) that outlives the call, then freed once the call
        /// returns -- Ghostty only borrows the completion struct for the duration of the call.
        private static func sendClipboardCompletion(
            surface: ghostty_surface_t,
            contents: [(mime: String, data: Data)],
            available: [String],
            state: UnsafeMutableRawPointer?,
            confirmed: Bool,
            remember: Bool
        ) {
            var cStrings: [UnsafeMutablePointer<CChar>] = []
            var cDatas: [UnsafeMutableRawPointer] = []
            defer {
                cStrings.forEach { free($0) }
                cDatas.forEach { $0.deallocate() }
            }

            var cContents: [ghostty_clipboard_content_s] = []
            for entry in contents {
                guard let mime = strdup(entry.mime) else { continue }
                cStrings.append(mime)
                let byteCount = entry.data.count
                // `allocate(byteCount: 0, ...)` is legal and returns a valid (non-dereferenceable) pointer.
                // Only copy when there is something to copy -- an empty Data's baseAddress is unreliable
                // to dereference, and there is nothing to move for a 0-byte payload anyway.
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 1)
                cDatas.append(buffer)
                if byteCount > 0 {
                    entry.data.withUnsafeBytes { source in
                        if let base = source.baseAddress {
                            buffer.copyMemory(from: base, byteCount: byteCount)
                        }
                    }
                }
                cContents.append(ghostty_clipboard_content_s(mime: mime, data: buffer.assumingMemoryBound(to: CChar.self), len: byteCount))
            }

            var cAvailable: [UnsafePointer<CChar>?] = []
            for mime in available {
                guard let str = strdup(mime) else { continue }
                cStrings.append(str)
                cAvailable.append(UnsafePointer(str))
            }

            cContents.withUnsafeBufferPointer { contentsBuf in
                cAvailable.withUnsafeBufferPointer { availableBuf in
                    var complete = ghostty_clipboard_complete_s(
                        contents: contentsBuf.baseAddress,
                        contents_len: contentsBuf.count,
                        available: availableBuf.baseAddress,
                        available_len: availableBuf.count,
                        confirmed: confirmed,
                        remember: remember)
                    ghostty_surface_complete_clipboard_request(surface, &complete, state)
                }
            }
        }
    }
#endif
