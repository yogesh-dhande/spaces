import Foundation
import streamctl

extension AppKitController {
    enum OutlineItem {
        case settings
        case project(ProjectSummary)
        case workspace(ProjectSummary, WorkspaceSummary)
    }
}
