import Testing

@testable import spacesdevicecore

/// The visibility outline both clients build: device -> project -> workspace on the Mac's Workspaces
/// dialog, project -> workspace on the iOS Workspaces sheet. It is the only surface that lists hidden
/// rows, so these cover that it lists everything, reports the right counts, and dims — without
/// disabling — the children a hidden project is suppressing.
@Suite struct WorkspaceVisibilityTreeTests {
    private static let mac = WorkspaceVisibilityTree.Device(deviceID: "device-mac", name: "Local")
    private static let linux = WorkspaceVisibilityTree.Device(deviceID: "device-linux", name: "keptune")

    private static func project(_ id: String, name: String, isGitRepo: Bool = true, isHidden: Bool = false) -> WorkspaceVisibilityTree.Project {
        WorkspaceVisibilityTree.Project(id: id, name: name, isGitRepo: isGitRepo, isHidden: isHidden)
    }

    private static func workspace(_ id: String, name: String, isHidden: Bool = false, isDefault: Bool = false) -> WorkspaceVisibilityTree.Workspace {
        WorkspaceVisibilityTree.Workspace(id: id, name: name, isDefault: isDefault, isHidden: isHidden)
    }

    @Test func buildsDeviceProjectWorkspaceLevels() {
        let tree = WorkspaceVisibilityTree.build(
            devices: [Self.mac, Self.linux],
            projectsByDevice: ["device-mac": [Self.project("p1", name: "harbor")], "device-linux": [Self.project("p2", name: "atlas")]],
            workspacesByProject: [
                "p1": [Self.workspace("w1", name: "main", isDefault: true), Self.workspace("w2", name: "feature")],
                "p2": [Self.workspace("w3", name: "main", isDefault: true)],
            ], query: "")

        #expect(tree.map(\.deviceID) == ["device-mac", "device-linux"])
        #expect(tree[0].projects.map(\.projectID) == ["p1"])
        #expect(tree[1].projects.map(\.projectID) == ["p2"])
        // Default workspace first, then by name — the sidebar's own order.
        #expect(tree[0].projects[0].workspaces.map(\.name) == ["main", "feature"])
    }

    @Test func devicesWithoutProjectsStillAppear() {
        let tree = WorkspaceVisibilityTree.build(devices: [Self.mac, Self.linux], projectsByDevice: [:], workspacesByProject: [:], query: "")

        #expect(tree.map(\.deviceID) == ["device-mac", "device-linux"])
        #expect(tree.allSatisfy { $0.projects.isEmpty })
    }

    @Test func listsHiddenWorkspacesAndHiddenProjects() {
        let projects = WorkspaceVisibilityTree.projectNodes(
            projects: [Self.project("p1", name: "harbor", isHidden: true)],
            workspacesByProject: ["p1": [Self.workspace("w1", name: "main", isDefault: true), Self.workspace("w2", name: "old", isHidden: true)]],
            query: "")

        let project = projects[0]
        #expect(project.workspaces.map(\.workspaceID) == ["w1", "w2"])
        #expect(project.isChecked == false)
        #expect(project.workspaces.map(\.isChecked) == [true, false])
    }

    @Test func gitProjectReportsShownCount() {
        let projects = WorkspaceVisibilityTree.projectNodes(
            projects: [Self.project("p1", name: "harbor")],
            workspacesByProject: ["p1": [Self.workspace("w1", name: "main", isDefault: true), Self.workspace("w2", name: "old", isHidden: true)]],
            query: "")

        #expect(projects[0].trailingText == "1 of 2 shown")
    }

    @Test func hiddenProjectReportsProjectHiddenAndDimsItsSubtree() {
        let projects = WorkspaceVisibilityTree.projectNodes(
            projects: [Self.project("p1", name: "harbor", isHidden: true)],
            workspacesByProject: ["p1": [Self.workspace("w1", name: "main", isDefault: true), Self.workspace("w2", name: "feature")]], query: "")

        let project = projects[0]
        #expect(project.trailingText == "project hidden")
        #expect(project.isDimmed)
        #expect(project.workspaces.allSatisfy { $0.isDimmed })
        // Dimmed, not suppressed: the children keep their own flags and stay individually toggleable.
        #expect(project.workspaces.allSatisfy { $0.isChecked })
        #expect(project.workspaces.map(\.workspaceID) == ["w1", "w2"])
    }

    @Test func shownProjectSubtreeIsNotDimmed() {
        let projects = WorkspaceVisibilityTree.projectNodes(
            projects: [Self.project("p1", name: "harbor")], workspacesByProject: ["p1": [Self.workspace("w1", name: "main", isDefault: true)]],
            query: "")

        #expect(projects[0].isDimmed == false)
        #expect(projects[0].workspaces.allSatisfy { !$0.isDimmed })
    }

    @Test func nonGitProjectIsOneFlatRowDrivingItsSingleWorkspace() {
        let projects = WorkspaceVisibilityTree.projectNodes(
            projects: [Self.project("p1", name: "notes", isGitRepo: false)],
            workspacesByProject: ["p1": [Self.workspace("w1", name: "notes", isHidden: true, isDefault: true)]], query: "")

        let project = projects[0]
        #expect(project.workspaces.isEmpty)
        #expect(project.isExpandable == false)
        #expect(project.trailingText == "")
        #expect(project.toggle == .workspace(workspaceID: "w1", isHidden: true))
        #expect(project.isChecked == false)
    }

    @Test func nonGitProjectRowIsNeverDimmed() {
        // Its one flag is the workspace flag its own checkbox drives, so there is no second flag
        // suppressing it and nothing for dimming to say.
        let projects = WorkspaceVisibilityTree.projectNodes(
            projects: [Self.project("p1", name: "notes", isGitRepo: false, isHidden: true)],
            workspacesByProject: ["p1": [Self.workspace("w1", name: "notes", isDefault: true)]], query: "")

        #expect(projects[0].isDimmed == false)
        #expect(projects[0].toggle == .workspace(workspaceID: "w1", isHidden: false))
    }

    @Test func gitProjectRowTogglesTheProjectFlag() {
        let projects = WorkspaceVisibilityTree.projectNodes(
            projects: [Self.project("p1", name: "harbor")], workspacesByProject: ["p1": [Self.workspace("w1", name: "main", isDefault: true)]],
            query: "")

        #expect(projects[0].toggle == .project(isHidden: false))
        #expect(projects[0].isExpandable)
    }

    @Test func workspaceMatchKeepsItsProjectAndDeviceAncestors() {
        let tree = WorkspaceVisibilityTree.build(
            devices: [Self.mac, Self.linux],
            projectsByDevice: ["device-mac": [Self.project("p1", name: "harbor")], "device-linux": [Self.project("p2", name: "atlas")]],
            workspacesByProject: [
                "p1": [Self.workspace("w1", name: "main", isDefault: true), Self.workspace("w2", name: "lantern")],
                "p2": [Self.workspace("w3", name: "main", isDefault: true)],
            ], query: "lantern")

        #expect(tree.map(\.deviceID) == ["device-mac"])
        #expect(tree[0].projects.map(\.projectID) == ["p1"])
        #expect(tree[0].projects[0].workspaces.map(\.workspaceID) == ["w2"])
    }

    @Test func projectMatchKeepsEveryChild() {
        let projects = WorkspaceVisibilityTree.projectNodes(
            projects: [Self.project("p1", name: "harbor"), Self.project("p2", name: "atlas")],
            workspacesByProject: [
                "p1": [Self.workspace("w1", name: "main", isDefault: true), Self.workspace("w2", name: "feature")],
                "p2": [Self.workspace("w3", name: "main", isDefault: true)],
            ], query: "harbor")

        #expect(projects.map(\.projectID) == ["p1"])
        #expect(projects[0].workspaces.map(\.workspaceID) == ["w1", "w2"])
    }

    @Test func searchMatchesFuzzilyRatherThanBySubstring() {
        let projects = WorkspaceVisibilityTree.projectNodes(
            projects: [Self.project("p1", name: "harbor"), Self.project("p2", name: "atlas")],
            workspacesByProject: [
                "p1": [Self.workspace("w1", name: "main", isDefault: true)], "p2": [Self.workspace("w2", name: "main", isDefault: true)],
            ], query: "hbr")

        #expect(projects.map(\.projectID) == ["p1"])
    }

    @Test func searchKeepsTheProjectCountOfTheWholeProject() {
        let projects = WorkspaceVisibilityTree.projectNodes(
            projects: [Self.project("p1", name: "harbor")],
            workspacesByProject: [
                "p1": [
                    Self.workspace("w1", name: "main", isDefault: true), Self.workspace("w2", name: "lantern"),
                    Self.workspace("w3", name: "old", isHidden: true),
                ]
            ], query: "lantern")

        #expect(projects[0].workspaces.map(\.workspaceID) == ["w2"])
        #expect(projects[0].trailingText == "2 of 3 shown")
    }

    @Test func searchPreservesListOrderInsteadOfRankingMatches() {
        let projects = WorkspaceVisibilityTree.projectNodes(
            projects: [Self.project("p1", name: "atlas-mirror"), Self.project("p2", name: "atlas")],
            workspacesByProject: [
                "p1": [Self.workspace("w1", name: "main", isDefault: true)], "p2": [Self.workspace("w2", name: "main", isDefault: true)],
            ], query: "atlas")

        #expect(projects.map(\.projectID) == ["p1", "p2"])
    }

    @Test func nonMatchingDeviceDropsOutWhileSearching() {
        let tree = WorkspaceVisibilityTree.build(
            devices: [Self.mac, Self.linux],
            projectsByDevice: ["device-mac": [Self.project("p1", name: "harbor")], "device-linux": [Self.project("p2", name: "atlas")]],
            workspacesByProject: ["p1": [Self.workspace("w1", name: "main", isDefault: true)], "p2": [Self.workspace("w2", name: "main")]],
            query: "atlas")

        #expect(tree.map(\.deviceID) == ["device-linux"])
    }

    @Test func deviceNameMatchKeepsEverythingOnThatDevice() {
        let tree = WorkspaceVisibilityTree.build(
            devices: [Self.mac, Self.linux],
            projectsByDevice: ["device-mac": [Self.project("p1", name: "harbor")], "device-linux": [Self.project("p2", name: "atlas")]],
            workspacesByProject: [
                "p1": [Self.workspace("w1", name: "main", isDefault: true)], "p2": [Self.workspace("w2", name: "main", isDefault: true)],
            ], query: "keptune")

        #expect(tree.map(\.deviceID) == ["device-linux"])
        #expect(tree[0].projects[0].workspaces.map(\.workspaceID) == ["w2"])
    }

    @Test func blankQueryReturnsTheWholeTree() {
        let projects = WorkspaceVisibilityTree.projectNodes(
            projects: [Self.project("p1", name: "harbor")], workspacesByProject: ["p1": [Self.workspace("w1", name: "main", isDefault: true)]],
            query: "   ")

        #expect(projects[0].workspaces.map(\.workspaceID) == ["w1"])
    }
}
