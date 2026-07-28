import Foundation

public struct GhosttyTerminalSnapshot: Codable, Sendable, Equatable {
    public struct Cell: Codable, Sendable, Equatable {
        public let codepoint: UInt32
        public let foregroundRGB: UInt32
        public let backgroundRGB: UInt32
        public let flags: UInt16

        public init(codepoint: UInt32, foregroundRGB: UInt32, backgroundRGB: UInt32, flags: UInt16) {
            self.codepoint = codepoint
            self.foregroundRGB = foregroundRGB
            self.backgroundRGB = backgroundRGB
            self.flags = flags
        }
    }

    public let columns: Int
    public let rows: Int
    public let cursorColumn: Int
    public let cursorRow: Int
    public let cursorVisible: Bool
    public let defaultForegroundRGB: UInt32
    public let defaultBackgroundRGB: UInt32
    public let cells: [Cell]
    /// True when the exporting terminal has a mouse tracking mode enabled. Clients arbitrate a pane
    /// click against this: while it is set the click belongs to the application, not to selection.
    public let mouseReportingActive: Bool
    /// The exporting terminal's shift-capture request as 0 = unset, 1 = false, 2 = true.
    public let mouseShiftCapture: UInt8

    public static let mouseShiftCaptureUnset: UInt8 = 0
    public static let mouseShiftCaptureDisabled: UInt8 = 1
    public static let mouseShiftCaptureEnabled: UInt8 = 2

    public init(
        columns: Int, rows: Int, cursorColumn: Int, cursorRow: Int, cursorVisible: Bool, defaultForegroundRGB: UInt32, defaultBackgroundRGB: UInt32,
        cells: [Cell], mouseReportingActive: Bool = false, mouseShiftCapture: UInt8 = 0
    ) {
        self.columns = columns
        self.rows = rows
        self.cursorColumn = cursorColumn
        self.cursorRow = cursorRow
        self.cursorVisible = cursorVisible
        self.defaultForegroundRGB = defaultForegroundRGB
        self.defaultBackgroundRGB = defaultBackgroundRGB
        self.cells = cells
        self.mouseReportingActive = mouseReportingActive
        self.mouseShiftCapture = mouseShiftCapture
    }
}

public struct GhosttyRenderFrame: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public let version: Int
    public let sessionRevision: UInt64?
    public let ownerEpoch: UInt64
    public let columns: Int
    public let rows: Int
    public let snapshot: GhosttyTerminalSnapshot

    public init(version: Int = Self.currentVersion, sessionRevision: UInt64?, ownerEpoch: UInt64, snapshot: GhosttyTerminalSnapshot) {
        self.version = version
        self.sessionRevision = sessionRevision
        self.ownerEpoch = ownerEpoch
        self.columns = snapshot.columns
        self.rows = snapshot.rows
        self.snapshot = snapshot
    }

    public static func encode(_ frame: GhosttyRenderFrame) throws -> Data { try JSONEncoder().encode(frame) }

    public static func decode(_ data: Data) throws -> GhosttyRenderFrame { try JSONDecoder().decode(GhosttyRenderFrame.self, from: data) }
}
