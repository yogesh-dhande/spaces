import Foundation

#if canImport(UIKit)
    import UIKit

    public enum GhosttyRemoteTerminalViewport {
        public static let contentInsets = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

        public static func reportedSize(rawColumns: Int, rawRows: Int, bounds _: CGRect, idiom _: UIUserInterfaceIdiom) -> (columns: Int, rows: Int) {
            return (columns: max(rawColumns, 1), rows: max(rawRows, 1))
        }
    }
#endif
