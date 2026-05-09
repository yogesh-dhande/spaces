import AppKit
import Foundation
import GhosttyKit

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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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

    private static func completeClipboardRequest(userdata: UnsafeMutableRawPointer?, string: String, state: UnsafeMutableRawPointer?, confirmed: Bool)
    {
        guard let userdata else { return }
        let view = Unmanaged<GhosttyEmbeddedTerminalView>.fromOpaque(userdata).takeUnretainedValue()
        guard let surface = view.surface else { return }
        string.withCString { pointer in ghostty_surface_complete_clipboard_request(surface, pointer, state, confirmed) }
    }
}
