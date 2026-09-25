#if os(macOS)
    import Foundation
    import XCTest
    import spacesterminalcore

    @testable import spacesterminalghostty

    /// How the macOS-hosted daemon reads a forwarded click's position.
    ///
    /// A click's normalized position names one cell as that cell's center in the sender's grid
    /// (`TerminalControlMouseButtonPayload`), and this host has to put the pointer inside that same cell on
    /// its own surface before handing the button to Ghostty, which resolves a pointer back to a cell from
    /// pixels. The surface's pixels are not the grid: Ghostty lays the grid out past its own padding and
    /// leaves whatever does not tile into a whole cell over at the far edge, so reading the position as a
    /// fraction of the surface drifts further into the neighbouring cell the further from the origin the
    /// click is.
    final class GhosttyEmbeddedMouseButtonPointerTests: XCTestCase {
        private let columns = 80
        private let rows = 24
        private let cellWidthPx = 9.0
        private let cellHeightPx = 19.0

        /// Ghostty's padding on the daemon's headless surface: the 2pt default at the fixed content scale
        /// those sessions render at.
        private var paddingPx: Double { GhosttySurfaceGridPadding.perSidePixels(scale: 2.0) }

        /// A surface the grid does not tile exactly, which is the ordinary case: 7 pixels are left over
        /// horizontally and 11 vertically, on top of the padding on each side.
        private var surfaceWidthPx: Double { paddingPx * 2 + Double(columns) * cellWidthPx + 7 }
        private var surfaceHeightPx: Double { paddingPx * 2 + Double(rows) * cellHeightPx + 11 }

        func testTheDaemonPutsTheClickOnTheCellTheSenderNamed() {
            XCTAssertEqual(paddingPx, 4, "a headless session surface pads its grid, so the grid's origin is not the surface's")

            for (column, row) in [(0, 0), (columns - 1, rows - 1), (columns - 1, 0), (0, rows - 1), (37, 11)] {
                let pixels = pointerPixels(forCellCenterAt: column, row)
                XCTAssertEqual(resolvedCell(pixelX: pixels.x, pixelY: pixels.y).column, column, "the click must reach the column the sender clicked")
                XCTAssertEqual(resolvedCell(pixelX: pixels.x, pixelY: pixels.y).row, row, "the click must reach the row the sender clicked")
            }
        }

        func testTheClickLandsInTheMiddleOfTheCellRatherThanOnItsEdge() {
            let pixels = pointerPixels(forCellCenterAt: columns - 1, rows - 1)
            let cellOriginX = paddingPx + Double(columns - 1) * cellWidthPx
            let cellOriginY = paddingPx + Double(rows - 1) * cellHeightPx

            XCTAssertEqual(pixels.x, cellOriginX + cellWidthPx / 2, "an edge coordinate is what a rounding difference turns into the next cell")
            XCTAssertEqual(pixels.y, cellOriginY + cellHeightPx / 2)
            XCTAssertGreaterThan(pixels.x, paddingPx, "the pointer must be inside the grid, past the padding")
            XCTAssertGreaterThan(pixels.y, paddingPx)
        }

        /// Reading the same position as a fraction of the surface's pixels (what a scroll's pointer means)
        /// misses the cell the sender clicked once the padding and the leftover pixels have accumulated
        /// past a whole cell, which is the reason this conversion exists. The drift grows with the
        /// distance from the origin and shows in the later columns and rows; at the very last cell the
        /// grid's own clamp happens to hide it again.
        func testReadingTheSamePositionAgainstTheSurfacePixelsMissesTheCell() {
            let position = gridCenter(column: 47, row: 17)
            let proportional = resolvedCell(
                pixelX: min(position.x * surfaceWidthPx, surfaceWidthPx - 1), pixelY: min(position.y * surfaceHeightPx, surfaceHeightPx - 1))

            XCTAssertEqual(proportional.column, 48, "a surface-proportional reading lands one column past the click")
            XCTAssertEqual(proportional.row, 18, "a surface-proportional reading lands one row past the click")
        }

        private func gridCenter(column: Int, row: Int) -> TerminalScrollPointerPosition {
            let center = TerminalPointerGrid.center(column: column, row: row, columns: columns, rows: rows)
            return TerminalScrollPointerPosition(x: center.x, y: center.y)
        }

        private func pointerPixels(forCellCenterAt column: Int, _ row: Int) -> (x: Double, y: Double) {
            GhosttyEmbeddedTerminalSessionDriver.clickedCellCenterPixels(
                for: gridCenter(column: column, row: row), columns: columns, rows: rows, cellWidthPx: cellWidthPx, cellHeightPx: cellHeightPx)
        }

        /// Ghostty's own surface-to-grid conversion (`renderer/size.zig`, `Coordinate.convert`): drop the
        /// padding, divide by the cell size, clamp to the grid.
        private func resolvedCell(pixelX: Double, pixelY: Double) -> (column: Int, row: Int) {
            let column = Int(((pixelX - paddingPx) / cellWidthPx).rounded(.down))
            let row = Int(((pixelY - paddingPx) / cellHeightPx).rounded(.down))
            return (column: min(max(column, 0), columns - 1), row: min(max(row, 0), rows - 1))
        }
    }
#endif
