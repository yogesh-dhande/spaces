#if canImport(GhosttyKit)
    import Foundation
    import GhosttyKit
    import spacesterminalcore

    public enum GhosttyTerminalSnapshotCapture {
        nonisolated(unsafe) static var sessionCaptureHandlerForTesting: ((ghostty_session_t?) -> GhosttyTerminalSnapshot?)?
        /// Overrides `captureRenderStateFromSession` directly, letting a test control the drained scroll
        /// rects a render-state export sees (`sessionCaptureHandlerForTesting` alone always yields empty
        /// rects, since it wraps its snapshot in a default `CapturedSnapshot`). Checked ahead of that
        /// handler so a test that needs scroll rects can set this one instead.
        nonisolated(unsafe) static var sessionRenderStateCaptureHandlerForTesting: ((ghostty_session_t?) -> CapturedSnapshot?)?

        public struct CapturedSnapshot: Sendable, Equatable {
            public let snapshot: GhosttyTerminalSnapshot
            public let scrollRects: [GhosttyRenderScrollRectOperation]
            /// True when the exporting surface's scroll-rect ring buffer overflowed since the previous
            /// frame, so `scrollRects` does not fully describe content movement. Mirrors
            /// `ghostty_terminal_snapshot_s.scroll_carry_valid`, inverted (that field is true when the
            /// rects ARE trustworthy).
            public let scrollRectsOverflowed: Bool

            public init(snapshot: GhosttyTerminalSnapshot, scrollRects: [GhosttyRenderScrollRectOperation] = [], scrollRectsOverflowed: Bool = false)
            {
                self.snapshot = snapshot
                self.scrollRects = scrollRects
                self.scrollRectsOverflowed = scrollRectsOverflowed
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
            if let sessionRenderStateCaptureHandlerForTesting { return sessionRenderStateCaptureHandlerForTesting(session) }
            if let sessionCaptureHandlerForTesting { return sessionCaptureHandlerForTesting(session).map { CapturedSnapshot(snapshot: $0) } }
            guard let session else { return nil }
            var snapshot = ghostty_terminal_snapshot_s()
            guard ghostty_session_export_snapshot(session, &snapshot) else { return nil }
            defer { ghostty_terminal_snapshot_free(&snapshot) }
            return CapturedSnapshot(
                snapshot: makeSnapshot(from: snapshot), scrollRects: makeScrollRects(from: snapshot),
                scrollRectsOverflowed: !snapshot.scroll_carry_valid)
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
            let links = linkTable(of: snapshot)
            var cells: [GhosttyTerminalSnapshot.Cell] = []
            var clusters: [Int: String] = [:]
            var linkURLs: [Int: String] = [:]
            if let rawCells = snapshot.cells, cellCount > 0 {
                cells.reserveCapacity(cellCount)
                for (index, rawCell) in UnsafeBufferPointer(start: rawCells, count: cellCount).enumerated() {
                    cells.append(
                        GhosttyTerminalSnapshot.Cell(
                            codepoint: rawCell.codepoint, foregroundRGB: rawCell.foreground_rgb, backgroundRGB: rawCell.background_rgb,
                            flags: rawCell.flags))
                    if let cluster = cluster(for: rawCell) { GhosttyTerminalSnapshot.setCluster(cluster, forCell: index, in: &clusters) }
                    if let linkURL = linkURL(for: rawCell, in: links) { GhosttyTerminalSnapshot.setLinkURL(linkURL, forCell: index, in: &linkURLs) }
                }
            }

            return GhosttyTerminalSnapshot(
                columns: Int(snapshot.columns), rows: Int(snapshot.rows), cursorColumn: Int(snapshot.cursor_column),
                cursorRow: Int(snapshot.cursor_row), cursorVisible: snapshot.cursor_visible, defaultForegroundRGB: snapshot.default_foreground_rgb,
                defaultBackgroundRGB: snapshot.default_background_rgb, cells: cells, clusters: clusters, linkURLs: linkURLs,
                mouseReportingActive: snapshot.mouse_reporting_active, mouseShiftCapture: snapshot.mouse_shift_capture,
                selection: selection(of: snapshot), scrollbarTotal: snapshot.scrollbar_total, scrollbarOffset: snapshot.scrollbar_offset)
        }

        /// Decodes the snapshot's selection out of `selection_flags` and the four viewport-relative,
        /// grid-clipped endpoint fields. Ghostty already did the clipping and the viewport rebase (this
        /// is an embedded surface, so its exported snapshot IS the viewport), so this is a direct field
        /// copy with no projection math, unlike the headless core which has to rebase a screen-space
        /// selection into whichever viewport it is exporting.
        private static func selection(of snapshot: ghostty_terminal_snapshot_s) -> GhosttyTerminalSelectionRange? {
            let flags = snapshot.selection_flags
            guard flags & 0x1 != 0 else { return nil }
            return GhosttyTerminalSelectionRange(
                startColumn: snapshot.selection_start_x, startRow: snapshot.selection_start_y, endColumn: snapshot.selection_end_x,
                endRow: snapshot.selection_end_y, isRectangle: flags & 0x2 != 0, extendsAbove: flags & 0x4 != 0, extendsBelow: flags & 0x8 != 0)
        }

        /// Rebuilds a cell's grapheme cluster from the exported base codepoint plus the extra codepoints
        /// the snapshot carries. Cells with no extras — nearly all of them — carry no cluster and render
        /// from the base codepoint alone.
        private static func cluster(for cell: ghostty_terminal_snapshot_cell_s) -> String? {
            guard let extras = cell.grapheme_extras, cell.grapheme_extra_len > 0, let base = UnicodeScalar(cell.codepoint) else { return nil }
            var scalars = String.UnicodeScalarView()
            scalars.append(base)
            for extra in UnsafeBufferPointer(start: extras, count: Int(cell.grapheme_extra_len)) {
                // A surrogate or out-of-range value is not something the terminal can hold; the base
                // codepoint alone still renders the cell.
                guard let scalar = UnicodeScalar(extra) else { return nil }
                scalars.append(scalar)
            }
            return String(scalars)
        }

        /// The snapshot's deduplicated OSC 8 targets, decoded once per snapshot. Cells index into this
        /// table, so a link shared by a run of cells is decoded once and every cell in the run ends up
        /// with the same string.
        private static func linkTable(of snapshot: ghostty_terminal_snapshot_s) -> [String] {
            let linkCount = Int(snapshot.link_count)
            guard let rawLinks = snapshot.links, linkCount > 0 else { return [] }
            return UnsafeBufferPointer(start: rawLinks, count: linkCount).map {
                guard let bytes = $0.ptr, $0.len > 0 else { return "" }
                return String(decoding: UnsafeBufferPointer(start: bytes, count: Int($0.len)), as: UTF8.self)
            }
        }

        /// A cell's OSC 8 target. `link_index` is 1-based so that zero means "no link", which is what
        /// almost every cell carries.
        private static func linkURL(for cell: ghostty_terminal_snapshot_cell_s, in links: [String]) -> String? {
            guard cell.link_index > 0, Int(cell.link_index) <= links.count else { return nil }
            let url = links[Int(cell.link_index) - 1]
            return url.isEmpty ? nil : url
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
#endif
