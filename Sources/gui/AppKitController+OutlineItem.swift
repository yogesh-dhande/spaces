import Foundation
import streamctl

extension AppKitController {
    enum OutlineItem {
        case project(ProjectSummary)
        case workspace(ProjectSummary, WorkspaceSummary)
    }
}
