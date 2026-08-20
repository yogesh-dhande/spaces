import Foundation
import spacesterminalcore

#if canImport(UIKit)
    import UIKit

    public enum GhosttyRemoteTerminalViewport {
        public static let contentInsets = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

        public static func reportedSize(rawColumns: Int, rawRows: Int, bounds _: CGRect, idiom _: UIUserInterfaceIdiom) -> (columns: Int, rows: Int) {
            return (columns: max(rawColumns, 1), rows: max(rawRows, 1))
        }

        /// The monospaced cell size a terminal surface at `fontSize` measures, matching
        /// `GhosttyRemoteTerminalHostView`'s own private `cellMetrics()` (same font, same "W"-glyph
        /// width probe). Exposed here so the Copy pill's placement math (SwiftUI, outside the host view)
        /// can agree with the surface on where a row/column lands without duplicating the measurement.
        public static func cellMetrics(fontSize: TerminalFontSize) -> (width: CGFloat, height: CGFloat) {
            let font = UIFont.monospacedSystemFont(ofSize: CGFloat(fontSize.points), weight: .regular)
            let width = ceil(("W" as NSString).size(withAttributes: [.font: font]).width)
            let height = ceil(font.lineHeight)
            return (width: max(width, 1), height: max(height, 1))
        }
    }
#endif
