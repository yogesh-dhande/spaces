#if os(Linux)
    import Foundation
    import ghosttyvtshim
    import spacesterminalcore

    /// Encodes a mouse report with libghostty-vt's mouse encoder, configured from the session's
    /// live terminal. This is the Linux counterpart of the macOS daemon handing the pointer to its ghostty
    /// surface: both run ghostty's own encoder, so a click or a drag produces the same bytes on either host.
    enum GhosttyLinuxMouseEncoder {
        enum Action {
            case press
            case release
            case motion

            fileprivate var shimAction: SpacesGhosttyVtMouseAction {
                switch self {
                case .press: return SPACES_GHOSTTY_VT_MOUSE_ACTION_PRESS
                case .release: return SPACES_GHOSTTY_VT_MOUSE_ACTION_RELEASE
                case .motion: return SPACES_GHOSTTY_VT_MOUSE_ACTION_MOTION
                }
            }
        }

        /// Returns the encoded report, or nil when the encoder call fails. An event the terminal's current
        /// tracking mode does not report returns empty data. `button` is the button the event names; for
        /// `.motion` it is the held button, or 0 when none is held.
        static func encode(action: Action, button: UInt8, cellColumn: Int, cellRow: Int, mods: UInt32, session: OpaquePointer) -> Data? {
            var encodedPointer: UnsafeMutablePointer<CChar>?
            var encodedLength: size_t = 0
            let encoded = spaces_ghostty_vt_session_encode_mouse(
                session, UInt8(action.shimAction.rawValue), button, shimModifiers(for: mods), UInt16(clamping: cellColumn), UInt16(clamping: cellRow),
                &encodedPointer, &encodedLength)
            guard encoded else { return nil }
            defer { if let encodedPointer { spaces_ghostty_vt_free_buffer(encodedPointer) } }
            guard let encodedPointer, encodedLength > 0 else { return Data() }
            return Data(bytes: encodedPointer, count: encodedLength)
        }

        /// The session's terminal's mouse tracking level, which decides whether a wheel event belongs to the
        /// application or to the local viewport and which pointer motion clients forward.
        static func trackingLevel(session: OpaquePointer) -> TerminalMouseTrackingLevel {
            var level: UInt8 = 0
            guard spaces_ghostty_vt_session_mouse_tracking_level(session, &level) else { return .none }
            return TerminalMouseTrackingLevel(rawValue: level) ?? .none
        }

        /// Clients send ghostty's own `ghostty_input_mods_e` bits, whose four base modifiers sit in the
        /// same positions as the shim's mask. Everything above them (caps/num lock and the sided
        /// variants) has no place in a mouse report.
        private static func shimModifiers(for mods: UInt32) -> UInt16 { UInt16(truncatingIfNeeded: mods) & modifierMask }

        private static let modifierMask = UInt16(
            SPACES_GHOSTTY_VT_MODS_SHIFT | SPACES_GHOSTTY_VT_MODS_CTRL | SPACES_GHOSTTY_VT_MODS_ALT | SPACES_GHOSTTY_VT_MODS_SUPER)
    }
#endif
