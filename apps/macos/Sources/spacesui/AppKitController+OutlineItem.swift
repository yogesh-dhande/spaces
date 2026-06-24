import Foundation
import workspacecore

extension AppKitController {
    enum OutlineItem: Hashable {
        case device(String)
        case project(ProjectSummary)
        case workspace(ProjectSummary, WorkspaceSummary)
        case emptyProject(ProjectSummary)

        static func == (lhs: OutlineItem, rhs: OutlineItem) -> Bool {
            switch (lhs, rhs) {
            case (.device(let a), .device(let b)): return a == b
            case (.project(let a), .project(let b)): return a.id == b.id
            case (.workspace(_, let a), .workspace(_, let b)): return a.id == b.id
            case (.emptyProject(let a), .emptyProject(let b)): return a.id == b.id
            default: return false
            }
        }

        func hash(into hasher: inout Hasher) {
            switch self {
            case .device(let deviceID):
                hasher.combine(3)
                hasher.combine(deviceID)
            case .project(let project):
                hasher.combine(0)
                hasher.combine(project.id)
            case .workspace(_, let workspace):
                hasher.combine(2)
                hasher.combine(workspace.id)
            case .emptyProject(let project):
                hasher.combine(1)
                hasher.combine(project.id)
            }
        }
    }

    /// NSObject wrapper for OutlineItem. NSOutlineView tracks expansion state via
    /// pointer identity on items, which is unreliable for Swift value types bridged
    /// through __SwiftValue (each bridge produces a fresh box). Returning the same
    /// OutlineItemRef instance for the same logical item gives NSOutlineView stable
    /// identity while still letting the content (item) update across reloads.
    final class OutlineItemRef: NSObject {
        var item: OutlineItem
        init(_ item: OutlineItem) { self.item = item }
    }
}

extension AppKitController.OutlineItem {
    var cacheKey: String {
        switch self {
        case .device(let deviceID): return "d:\(deviceID)"
        case .project(let project): return "p:\(project.id)"
        case .workspace(_, let workspace): return "w:\(workspace.id)"
        case .emptyProject(let project): return "e:\(project.id)"
        }
    }
}
