import Foundation
import spacesterminalcore

#if canImport(UIKit)
    import UIKit

    public enum GhosttyRemoteTerminalViewport {
        public static let contentInsets = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

        public static func reportedSize(rawColumns: Int, rawRows: Int, bounds _: CGRect, idiom _: UIUserInterfaceIdiom) -> (columns: Int, rows: Int) {
            return (columns: max(rawColumns, 1), rows: max(rawRows, 1))
        }

        /// The monospaced cell size a terminal surface at `fontSize` measures. Exposed here so the
        /// Copy pill's placement math (SwiftUI, outside the host view) can agree with the surface on
        /// where a row/column lands without duplicating the measurement.
        ///
        /// Consults `GhosttyRemoteTerminalHostView.cellMetricsCache` first (a real
        /// `ghostty_surface_size()` read converted from device pixels back to points, `px / scale`),
        /// since that is what the surface actually renders with; only when nothing is cached yet does
        /// this fall back to the `UIFont.monospacedSystemFont` "W"-glyph probe `GhosttyRemoteTerminalHostView`
        /// itself falls back to before a surface exists. `scale` defaults to the main screen's, matching
        /// the host view's own fallback when it has no window yet.
        @MainActor public static func cellMetrics(fontSize: TerminalFontSize, scale: CGFloat = UIScreen.main.scale) -> (
            width: CGFloat, height: CGFloat
        ) {
            if let cached = GhosttyRemoteTerminalHostView.cellMetricsCache.cellPixelSize(fontSizePoints: fontSize.rawValue, scale: Double(scale)) {
                return (width: max(CGFloat(cached.width) / scale, 1), height: max(CGFloat(cached.height) / scale, 1))
            }
            let font = UIFont.monospacedSystemFont(ofSize: CGFloat(fontSize.points), weight: .regular)
            let width = ceil(("W" as NSString).size(withAttributes: [.font: font]).width)
            let height = ceil(font.lineHeight)
            return (width: max(width, 1), height: max(height, 1))
        }
    }
#endif
