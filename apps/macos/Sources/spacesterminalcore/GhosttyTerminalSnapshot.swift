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

    public init(
        columns: Int, rows: Int, cursorColumn: Int, cursorRow: Int, cursorVisible: Bool, defaultForegroundRGB: UInt32, defaultBackgroundRGB: UInt32,
        cells: [Cell]
    ) {
        self.columns = columns
        self.rows = rows
        self.cursorColumn = cursorColumn
        self.cursorRow = cursorRow
        self.cursorVisible = cursorVisible
        self.defaultForegroundRGB = defaultForegroundRGB
        self.defaultBackgroundRGB = defaultBackgroundRGB
        self.cells = cells
    }
}
