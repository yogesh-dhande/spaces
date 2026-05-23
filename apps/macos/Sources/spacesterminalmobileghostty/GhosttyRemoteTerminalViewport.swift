import Foundation

#if canImport(UIKit)
    import UIKit

    public enum GhosttyRemoteTerminalViewport {
        public static let contentInsets = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        private static let minimumPhoneColumns = 24
        private static let estimatedPhoneColumnWidth: CGFloat = 9.5

        public static func reportedSize(rawColumns: Int, rawRows: Int, bounds: CGRect, idiom: UIUserInterfaceIdiom) -> (columns: Int, rows: Int) {
            let resolvedRows = max(rawRows, 1)
            let resolvedColumns = max(rawColumns, 1)
            guard idiom == .phone else { return (columns: resolvedColumns, rows: resolvedRows) }

            let contentWidth = bounds.inset(by: contentInsets).width
            guard contentWidth > 0 else { return (columns: resolvedColumns, rows: resolvedRows) }

            let readableColumns = max(minimumPhoneColumns, Int((contentWidth / estimatedPhoneColumnWidth).rounded(.down)))
            return (columns: min(resolvedColumns, readableColumns), rows: resolvedRows)
        }
    }
#endif
