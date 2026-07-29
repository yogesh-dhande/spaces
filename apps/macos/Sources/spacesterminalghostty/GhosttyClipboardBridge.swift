#if canImport(AppKit) && canImport(GhosttyKit)
    import AppKit
    import Foundation
    import GhosttyKit
    import spacesterminalcore

    enum GhosttyClipboardBridge {
        static func readClipboard(userdata: UnsafeMutableRawPointer?, state: UnsafeMutableRawPointer?) -> Bool {
            let text = NSPasteboard.general.string(forType: .string) ?? ""
            completeClipboardRequest(userdata: userdata, string: text, state: state, confirmed: false)
            return true
        }

        static func confirmReadClipboard(userdata: UnsafeMutableRawPointer?, content: UnsafePointer<CChar>?, state: UnsafeMutableRawPointer?) {
            let text = content.map(String.init(cString:)) ?? ""
            completeClipboardRequest(userdata: userdata, string: text, state: state, confirmed: true)
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

        static func preferredPlainText(from content: UnsafeBufferPointer<ghostty_clipboard_content_s>) -> String? {
            for item in content {
                guard let mime = item.mime.map(String.init(cString:)), mime.hasPrefix("text/plain"), let data = item.data else { continue }
                return String(cString: data)
            }
            return nil
        }

        private static func completeClipboardRequest(
            userdata: UnsafeMutableRawPointer?, string: String, state: UnsafeMutableRawPointer?, confirmed: Bool
        ) {
            guard let userdata else { return }
            // The surface userdata is the daemon's engine-actor-isolated `GhosttyEmbeddedSurfaceUserData`
            // (mirror surfaces set none, so this only ever runs for daemon surfaces — the guard above
            // early-returns for the null mirror userdata). Hop to the engine actor to read the surface,
            // preserving the pre-existing "complete on a later turn" pattern.
            let surfaceUserData = Unmanaged<GhosttyEmbeddedSurfaceUserData>.fromOpaque(userdata).takeUnretainedValue()
            let stateAddress = state.map { UInt(bitPattern: $0) }
            Task { @TerminalEngineActor in
                guard let surface = surfaceUserData.surface() else { return }
                let statePointer = stateAddress.flatMap(UnsafeMutableRawPointer.init(bitPattern:))
                string.withCString { pointer in ghostty_surface_complete_clipboard_request(surface, pointer, statePointer, confirmed) }
            }
        }
    }
#endif
