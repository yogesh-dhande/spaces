/// Which pointer input the program tracking the mouse asks the terminal to report. The raw values are
/// the byte the render-frame codec carries, and match the fork's `mouse_tracking_level` snapshot field.
public enum TerminalMouseTrackingLevel: UInt8, Codable, Sendable, Equatable {
    /// No tracking mode is enabled; the pointer belongs to selection.
    case none = 0
    /// X10 or normal tracking (modes 9, 1000): presses, releases and the wheel.
    case clicks = 1
    /// Button-event tracking (mode 1002): clicks plus motion while a reported button is held.
    case buttonMotion = 2
    /// Any-event tracking (mode 1003): clicks plus all motion, with or without a button held.
    case anyMotion = 3

    /// Whether any tracking mode is enabled.
    public var isActive: Bool { self != .none }

    /// Whether a pointer move with `buttonHeld` reaches the program under this level.
    public func reportsMotion(buttonHeld: Bool) -> Bool {
        switch self {
        case .none, .clicks: return false
        case .buttonMotion: return buttonHeld
        case .anyMotion: return true
        }
    }
}
