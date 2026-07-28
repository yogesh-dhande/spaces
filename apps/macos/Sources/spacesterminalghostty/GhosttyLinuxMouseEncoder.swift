#if os(Linux)
    import Foundation
    import ghosttyvtshim
    import spacesterminalcore

    /// Encodes a mouse button report with libghostty-vt's mouse encoder, configured from the session's
    /// live terminal. This is the Linux counterpart of the macOS daemon handing the button to its ghostty
    /// surface: both run ghostty's own encoder, so a click produces the same bytes on either host.
    enum GhosttyLinuxMouseEncoder {
        /// Returns the encoded report, or nil when the encoder call fails. An event the terminal's current
        /// tracking mode does not report returns empty data.
        static func encode(button: UInt8, pressed: Bool, cellColumn: Int, cellRow: Int, mods: UInt32, session: OpaquePointer) -> Data? {
            var encodedPointer: UnsafeMutablePointer<CChar>?
            var encodedLength: size_t = 0
            let action = pressed ? SPACES_GHOSTTY_VT_MOUSE_ACTION_PRESS : SPACES_GHOSTTY_VT_MOUSE_ACTION_RELEASE
            let encoded = spaces_ghostty_vt_session_encode_mouse(
                session, UInt8(action.rawValue), button, shimModifiers(for: mods), UInt16(clamping: cellColumn), UInt16(clamping: cellRow),
                &encodedPointer, &encodedLength)
            guard encoded else { return nil }
            defer { if let encodedPointer { spaces_ghostty_vt_free_buffer(encodedPointer) } }
            guard let encodedPointer, encodedLength > 0 else { return Data() }
            return Data(bytes: encodedPointer, count: encodedLength)
        }

        /// Reports whether the session's terminal has a mouse tracking mode enabled, which is what decides
        /// whether a wheel event belongs to the application or to the local viewport.
        static func trackingIsActive(session: OpaquePointer) -> Bool {
            var active = false
            guard spaces_ghostty_vt_session_mouse_tracking_active(session, &active) else { return false }
            return active
        }

        /// Clients send ghostty's own `ghostty_input_mods_e` bits, whose four base modifiers sit in the
        /// same positions as the shim's mask. Everything above them (caps/num lock and the sided
        /// variants) has no place in a mouse report.
        private static func shimModifiers(for mods: UInt32) -> UInt16 { UInt16(truncatingIfNeeded: mods) & modifierMask }

        private static let modifierMask = UInt16(
            SPACES_GHOSTTY_VT_MODS_SHIFT | SPACES_GHOSTTY_VT_MODS_CTRL | SPACES_GHOSTTY_VT_MODS_ALT | SPACES_GHOSTTY_VT_MODS_SUPER)
    }
#endif
