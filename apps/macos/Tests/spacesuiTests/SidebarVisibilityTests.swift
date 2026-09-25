import Testing
import spacesdevicecore
import workspacecore

@testable import spacesui

/// What the sidebar shows. Every surface that renders the sidebar's model reads through these rules,
/// so a hidden project has to disappear from all of them exactly the way a hidden workspace does.
@Suite struct SidebarVisibilityTests {
    private static func project(
        _ id: String, isGitRepo: Bool = true, kind: ProjectKind = .standard, isHidden: Bool = false, deviceID: String = "device-mac"
    ) -> ProjectSummary {
        ProjectSummary(
            id: id, name: id, dir: "/repos/\(id)", isGitRepo: isGitRepo, defaultBranch: "main", kind: kind, isHidden: isHidden, deviceID: deviceID)
    }

    /// The device's home project as the daemon reports it: non-git, named `~`, and ordered last by the
    /// daemon's own `ORDER BY name`, since `~` sorts after every letter.
    private static func homeProject(_ id: String = "home", deviceID: String = "device-mac") -> ProjectSummary {
        ProjectSummary(
            id: id, name: "~", dir: "/Users/someone", isGitRepo: false, defaultBranch: nil, kind: .home, isHidden: false, deviceID: deviceID)
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

    @Test func homeProjectIsListedFirstInItsDeviceSection() {
        let projects = [Self.project("alpha"), Self.project("beta"), Self.homeProject()]
        let workspaces = ["alpha": [Self.workspace("w1")], "beta": [Self.workspace("w2")], "home": [Self.workspace("w3")]]

        let visible = SidebarVisibility.deviceProjects(projects, deviceID: "device-mac", workspacesByProject: workspaces)

        #expect(visible.map(\.id) == ["home", "alpha", "beta"], "the home row opens the device section and the rest keep the daemon's order")
    }

    @Test func hidingTheHomeProjectTakesItsRowOutOfTheSidebar() {
        // Hiding is the one visibility control the home row has, and it works through the same flag a
        // non-git project's single workspace uses.
        let projects = [Self.homeProject()]
        let workspaces = ["home": [Self.workspace("w3", isHidden: true)]]

        #expect(SidebarVisibility.deviceProjects(projects, deviceID: "device-mac", workspacesByProject: workspaces).isEmpty)
    }

    @Test func eachDeviceSectionOpensWithItsOwnHomeRow() {
        let projects = [
            Self.project("alpha"), Self.homeProject("home-mac"), Self.project("linux-app", deviceID: "device-linux"),
            Self.homeProject("home-linux", deviceID: "device-linux"),
        ]
        let workspaces = [
            "alpha": [Self.workspace("w1")], "home-mac": [Self.workspace("w2")], "linux-app": [Self.workspace("w3")],
            "home-linux": [Self.workspace("w4")],
        ]

        #expect(
            SidebarVisibility.deviceProjects(projects, deviceID: "device-mac", workspacesByProject: workspaces).map(\.id) == ["home-mac", "alpha"])
        #expect(
            SidebarVisibility.deviceProjects(projects, deviceID: "device-linux", workspacesByProject: workspaces).map(\.id) == [
                "home-linux", "linux-app",
            ])
    }
}
