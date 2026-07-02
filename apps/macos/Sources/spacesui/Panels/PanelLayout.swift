import Foundation

/// Identifies one panel — a tabbed, splittable container of panes. A workspace-scoped
/// panel lives in the main window's right pane and only holds that workspace's targets;
/// a global panel backs an extra Spaces window and may mix targets from any workspace.
enum PanelScope: Hashable, Codable, Sendable {
    case workspace(deviceID: String, workspaceID: String)
    case globalWindow(panelWindowID: String)
}

/// The persisted document for one panel: its tabs, the selected tab, and the focused
/// pane, so reselecting a workspace (or relaunching the app) restores exactly where the
/// user was. Purely a value type — all mutations live in `PanelLayoutEngine`.
struct PanelLayout: Codable, Sendable, Equatable {
    /// Serialization envelope version for the `layout_json` client-DB column.
    static let currentVersion = 1

    var version: Int = PanelLayout.currentVersion
    var tabs: [PanelTab] = []
    var selectedTabID: String?
    var focusedPaneID: String?

    var isEmpty: Bool { tabs.isEmpty }
}

struct PanelTab: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var root: PaneNode
}

/// A tab's pane arrangement: a leaf pane, or a split holding two or more children with
/// relative weights. Splits of splits express mixed row/column layouts.
indirect enum PaneNode: Codable, Sendable, Equatable {
    case leaf(Pane)
    case split(PaneSplit)
}

struct PaneSplit: Codable, Sendable, Equatable {
    let id: String
    var orientation: PaneSplitOrientation
    /// Relative sizes, one per child, normalized by consumers (they need not sum to 1).
    var weights: [Double]
    var children: [PaneNode]
}

enum PaneSplitOrientation: String, Codable, Sendable {
    /// Children sit side by side (a split to the right adds a horizontal sibling).
    case horizontal
    /// Children stack top to bottom (a split downward adds a vertical sibling).
    case vertical
}

struct Pane: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var content: PaneContentDescriptor
}

/// What a pane shows. Only terminal sessions exist today; future content kinds (editor,
/// file preview) become new cases that older persisted layouts simply never contain.
enum PaneContentDescriptor: Codable, Sendable, Hashable {
    case terminalSession(deviceID: String, sessionID: String)

    var terminalSessionID: String? {
        switch self {
        case .terminalSession(_, let sessionID): return sessionID
        }
    }
}
