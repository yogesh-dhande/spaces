import Foundation
import Testing
import streamctl

@testable import gui

@Suite struct AppKitControllerGitActivityTests {
    @Test func retainedSidebarGitActivityKeepsOnlyCurrentGitWorkspaceEntries() {
        let retainedActivity = GitTrackedFileActivity(
            latestTrackedFileModificationDate: Date(),
            modifiedTrackedFileCount: 2,
            aheadCount: 1,
            behindCount: 0,
            comparedBaseBranch: "main")
        let staleActivity = GitTrackedFileActivity(
            latestTrackedFileModificationDate: nil,
            modifiedTrackedFileCount: 1)
        let nonGitActivity = GitTrackedFileActivity(
            latestTrackedFileModificationDate: nil,
            modifiedTrackedFileCount: 3)

        let result = AppKitController.retainedSidebarGitActivity(
            existing: [
                "workspace-retained": retainedActivity,
                "workspace-removed": staleActivity,
                "workspace-non-git": nonGitActivity,
            ],
            projects: [
                ProjectSummary(id: "project-git", name: "Git", dir: "/tmp/git", isGitRepo: true, defaultBranch: "main"),
                ProjectSummary(id: "project-plain", name: "Plain", dir: "/tmp/plain", isGitRepo: false, defaultBranch: nil),
            ],
            workspacesByProject: [
                "project-git": [
                    WorkspaceSummary(
                        id: "workspace-retained",
                        title: "Retained",
                        branch: "feature",
                        dir: "/tmp/git/retained",
                        isRunning: false,
                        isArchived: false,
                        isDefault: false)
                ],
                "project-plain": [
                    WorkspaceSummary(
                        id: "workspace-non-git",
                        title: "Non Git",
                        branch: nil,
                        dir: "/tmp/plain/non-git",
                        isRunning: false,
                        isArchived: false,
                        isDefault: false)
                ],
            ])

        #expect(result.count == 1)
        #expect(result["workspace-retained"]?.modifiedTrackedFileCount == 2)
        #expect(result["workspace-removed"] == nil)
        #expect(result["workspace-non-git"] == nil)
    }

    @Test func sidebarGitActivityPresentationUsesExistingActivityDuringRefresh() {
        let activity = GitTrackedFileActivity(
            latestTrackedFileModificationDate: nil,
            modifiedTrackedFileCount: 2,
            hasMergeConflicts: true)

        let presentation = AppKitController.sidebarGitActivityPresentation(
            projectIsGitRepo: true,
            activity: activity,
            isLoading: true)

        #expect(presentation?.label == "No tracked files • 2 uncommitted files")
        #expect(presentation?.statusSymbol == "exclamationmark.triangle.fill")
        #expect(presentation?.statusColorStyle == .warning)
    }

    @Test func sidebarGitActivityPresentationShowsPlaceholderWhileRefreshingWithoutActivity() {
        let presentation = AppKitController.sidebarGitActivityPresentation(
            projectIsGitRepo: true,
            activity: nil,
            isLoading: true)

        #expect(presentation?.label == "Refreshing git status…")
        #expect(presentation?.statusSymbol == "ellipsis.circle")
        #expect(presentation?.statusColorStyle == .metadata)
    }

    @Test func sidebarGitActivityPresentationHidesPlaceholderWhenIdleWithoutActivity() {
        let presentation = AppKitController.sidebarGitActivityPresentation(
            projectIsGitRepo: true,
            activity: nil,
            isLoading: false)

        #expect(presentation == nil)
    }
}
