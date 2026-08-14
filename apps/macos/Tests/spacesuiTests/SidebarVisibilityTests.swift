import Testing
import workspacecore

@testable import spacesui

/// What the sidebar shows. Every surface that renders the sidebar's model reads through these rules,
/// so a hidden project has to disappear from all of them exactly the way a hidden workspace does.
@Suite struct SidebarVisibilityTests {
    private static func project(_ id: String, isGitRepo: Bool = true, isHidden: Bool = false, deviceID: String = "device-mac") -> ProjectSummary {
        ProjectSummary(id: id, name: id, dir: "/repos/\(id)", isGitRepo: isGitRepo, defaultBranch: "main", isHidden: isHidden, deviceID: deviceID)
    }

    private static func workspace(_ id: String, isHidden: Bool = false) -> WorkspaceSummary {
        WorkspaceSummary(id: id, branch: id, dir: "/repos/\(id)", isRunning: false, isHidden: isHidden, isDefault: false)
    }

    @Test func shownWorkspaceInShownProjectIsVisible() {
        #expect(SidebarVisibility.isVisibleWorkspace(Self.workspace("w1"), inProject: Self.project("p1")))
    }

    @Test func hiddenWorkspaceIsNotVisible() {
        #expect(SidebarVisibility.isVisibleWorkspace(Self.workspace("w1", isHidden: true), inProject: Self.project("p1")) == false)
    }

    @Test func workspaceInHiddenProjectIsNotVisible() {
        #expect(SidebarVisibility.isVisibleWorkspace(Self.workspace("w1"), inProject: Self.project("p1", isHidden: true)) == false)
    }

    @Test func workspaceWithNoLoadedProjectIsNotVisible() {
        #expect(SidebarVisibility.isVisibleWorkspace(Self.workspace("w1"), inProject: nil) == false)
    }

    @Test func hiddenProjectLeavesTheSidebarEntirely() {
        let projects = [Self.project("p1"), Self.project("p2", isHidden: true)]
        let workspaces = ["p1": [Self.workspace("w1")], "p2": [Self.workspace("w2")]]

        let visible = SidebarVisibility.deviceProjects(projects, deviceID: "device-mac", workspacesByProject: workspaces)

        #expect(visible.map(\.id) == ["p1"])
    }

    @Test func deviceProjectsAreScopedToTheirDevice() {
        let projects = [Self.project("p1"), Self.project("p2", deviceID: "device-linux")]
        let workspaces = ["p1": [Self.workspace("w1")], "p2": [Self.workspace("w2")]]

        #expect(SidebarVisibility.deviceProjects(projects, deviceID: "device-linux", workspacesByProject: workspaces).map(\.id) == ["p2"])
    }

    @Test func gitProjectStaysListedWithEveryWorkspaceHidden() {
        // A git project keeps its header even with nothing under it: it still offers New Workspace.
        let projects = [Self.project("p1")]
        let workspaces = ["p1": [Self.workspace("w1", isHidden: true)]]

        #expect(SidebarVisibility.deviceProjects(projects, deviceID: "device-mac", workspacesByProject: workspaces).map(\.id) == ["p1"])
    }

    @Test func nonGitProjectDropsWhenItsSingleWorkspaceIsHidden() {
        let projects = [Self.project("p1", isGitRepo: false)]
        let workspaces = ["p1": [Self.workspace("w1", isHidden: true)]]

        #expect(SidebarVisibility.deviceProjects(projects, deviceID: "device-mac", workspacesByProject: workspaces).isEmpty)
    }

    @Test func nonGitProjectStaysWhenItsSingleWorkspaceIsShown() {
        let projects = [Self.project("p1", isGitRepo: false)]
        let workspaces = ["p1": [Self.workspace("w1")]]

        #expect(SidebarVisibility.deviceProjects(projects, deviceID: "device-mac", workspacesByProject: workspaces).map(\.id) == ["p1"])
    }
}
