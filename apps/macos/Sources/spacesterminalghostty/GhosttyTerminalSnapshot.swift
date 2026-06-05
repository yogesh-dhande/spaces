import Foundation
import GhosttyKit
import spacesterminalcore

public enum GhosttyTerminalSnapshotCapture {
    nonisolated(unsafe) static var sessionCaptureHandlerForTesting: ((ghostty_session_t?) -> GhosttyTerminalSnapshot?)?

    public struct CapturedSnapshot: Sendable, Equatable {
        public let snapshot: GhosttyTerminalSnapshot
        public let scrollRects: [GhosttyRenderScrollRectOperation]

        public init(snapshot: GhosttyTerminalSnapshot, scrollRects: [GhosttyRenderScrollRectOperation] = []) {
            self.snapshot = snapshot
            self.scrollRects = scrollRects
        }
    }

    public static func captureFromSurface(_ surface: ghostty_surface_t?) -> GhosttyTerminalSnapshot? {
        guard let surface else { return nil }
        var snapshot = ghostty_terminal_snapshot_s()
        guard ghostty_surface_export_snapshot(surface, &snapshot) else { return nil }
        defer { ghostty_terminal_snapshot_free(&snapshot) }
        return makeSnapshot(from: snapshot)
    }

    public static func captureFromSession(_ session: ghostty_session_t?) -> GhosttyTerminalSnapshot? {
        if let sessionCaptureHandlerForTesting { return sessionCaptureHandlerForTesting(session) }
        guard let session else { return nil }
        var snapshot = ghostty_terminal_snapshot_s()
        guard ghostty_session_export_snapshot(session, &snapshot) else { return nil }
        defer { ghostty_terminal_snapshot_free(&snapshot) }
        return makeSnapshot(from: snapshot)
    }

    public static func captureRenderStateFromSession(_ session: ghostty_session_t?) -> CapturedSnapshot? {
        if let sessionCaptureHandlerForTesting { return sessionCaptureHandlerForTesting(session).map { CapturedSnapshot(snapshot: $0) } }
        guard let session else { return nil }
        var snapshot = ghostty_terminal_snapshot_s()
        guard ghostty_session_export_snapshot(session, &snapshot) else { return nil }
        defer { ghostty_terminal_snapshot_free(&snapshot) }
        return CapturedSnapshot(snapshot: makeSnapshot(from: snapshot), scrollRects: makeScrollRects(from: snapshot))
    }

    public static func captureText(from surface: ghostty_surface_t?) -> String? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        guard size.columns > 0, size.rows > 0 else { return nil }

        var text = ghostty_text_s()
        let selection = visibleViewportSelection(columns: size.columns, rows: size.rows)
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let raw = text.text, text.text_len > 0 else { return "" }
        let bytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(raw), count: Int(text.text_len))
        return String(decoding: bytes, as: UTF8.self)
    }

    static func visibleViewportSelection(columns: UInt16, rows: UInt16) -> ghostty_selection_s {
        let maxColumn = UInt32(max(Int(columns) - 1, 0))
        let maxRow = UInt32(max(Int(rows) - 1, 0))
        return ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: maxColumn, y: maxRow),
            rectangle: false)
    }

    private static func makeSnapshot(from snapshot: ghostty_terminal_snapshot_s) -> GhosttyTerminalSnapshot {
        let cellCount = Int(snapshot.cell_count)
        let cells: [GhosttyTerminalSnapshot.Cell]
        if let rawCells = snapshot.cells, cellCount > 0 {
            let buffer = UnsafeBufferPointer(start: rawCells, count: cellCount)
            cells = buffer.map {
                GhosttyTerminalSnapshot.Cell(
                    codepoint: $0.codepoint, foregroundRGB: $0.foreground_rgb, backgroundRGB: $0.background_rgb, flags: $0.flags)
            }
        } else {
            cells = []
        }

        return GhosttyTerminalSnapshot(
            columns: Int(snapshot.columns), rows: Int(snapshot.rows), cursorColumn: Int(snapshot.cursor_column), cursorRow: Int(snapshot.cursor_row),
            cursorVisible: snapshot.cursor_visible, defaultForegroundRGB: snapshot.default_foreground_rgb,
            defaultBackgroundRGB: snapshot.default_background_rgb, cells: cells)
    }

    private static func makeScrollRects(from snapshot: ghostty_terminal_snapshot_s) -> [GhosttyRenderScrollRectOperation] {
        let operationCount = Int(snapshot.scroll_rect_count)
        guard let rawOperations = snapshot.scroll_rects, operationCount > 0 else { return [] }
        let buffer = UnsafeBufferPointer(start: rawOperations, count: operationCount)
        return buffer.map {
            GhosttyRenderScrollRectOperation(
                rowStart: Int($0.row_start), rowCount: Int($0.row_count), columnStart: Int($0.column_start), columnCount: Int($0.column_count),
                deltaRows: Int($0.delta_rows), deltaColumns: Int($0.delta_columns))
        }
    }
}
