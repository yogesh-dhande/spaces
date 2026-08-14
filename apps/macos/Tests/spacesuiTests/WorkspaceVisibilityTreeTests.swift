import Testing
import workspacecore

@testable import spacesui

/// The Workspaces dialog's device -> project -> workspace outline. It is the only surface that lists
/// hidden rows, so these cover that it lists everything, reports the right counts, and dims — without
/// disabling — the children a hidden project is suppressing.
@Suite struct WorkspaceVisibilityTreeTests {
    private static let mac = WorkspaceVisibilityTree.Device(deviceID: "device-mac", name: "Local")
    private static let linux = WorkspaceVisibilityTree.Device(deviceID: "device-linux", name: "keptune")

    private static func project(_ id: String, name: String, isGitRepo: Bool = true, isHidden: Bool = false, deviceID: String = "device-mac")
        -> ProjectSummary
    { ProjectSummary(id: id, name: name, dir: "/repos/\(name)", isGitRepo: isGitRepo, defaultBranch: "main", isHidden: isHidden, deviceID: deviceID) }

    private static func workspace(_ id: String, branch: String, isHidden: Bool = false, isDefault: Bool = false) -> WorkspaceSummary {
        WorkspaceSummary(id: id, branch: branch, dir: "/repos/\(branch)", isRunning: false, isHidden: isHidden, isDefault: isDefault)
    }

    @Test func buildsDeviceProjectWorkspaceLevels() {
        let tree = WorkspaceVisibilityTree.build(
            devices: [Self.mac, Self.linux],
            projects: [Self.project("p1", name: "harbor"), Self.project("p2", name: "atlas", deviceID: "device-linux")],
            workspacesByProject: [
                "p1": [Self.workspace("w1", branch: "main", isDefault: true), Self.workspace("w2", branch: "feature")],
                "p2": [Self.workspace("w3", branch: "main", isDefault: true)],
            ], query: "")

        #expect(tree.map(\.deviceID) == ["device-mac", "device-linux"])
        #expect(tree[0].projects.map(\.projectID) == ["p1"])
        #expect(tree[1].projects.map(\.projectID) == ["p2"])
        // Default workspace first, then by name — the sidebar's own order.
        #expect(tree[0].projects[0].workspaces.map(\.name) == ["main", "feature"])
    }

    @Test func devicesWithoutProjectsStillAppear() {
        let tree = WorkspaceVisibilityTree.build(devices: [Self.mac, Self.linux], projects: [], workspacesByProject: [:], query: "")

        #expect(tree.map(\.deviceID) == ["device-mac", "device-linux"])
        #expect(tree.allSatisfy { $0.projects.isEmpty })
    }

    @Test func listsHiddenWorkspacesAndHiddenProjects() {
        let tree = WorkspaceVisibilityTree.build(
            devices: [Self.mac], projects: [Self.project("p1", name: "harbor", isHidden: true)],
            workspacesByProject: [
                "p1": [Self.workspace("w1", branch: "main", isDefault: true), Self.workspace("w2", branch: "old", isHidden: true)]
            ], query: "")

        let project = tree[0].projects[0]
        #expect(project.workspaces.map(\.workspaceID) == ["w1", "w2"])
        #expect(project.isChecked == false)
        #expect(project.workspaces.map(\.isChecked) == [true, false])
    }

    @Test func gitProjectReportsShownCount() {
        let tree = WorkspaceVisibilityTree.build(
            devices: [Self.mac], projects: [Self.project("p1", name: "harbor")],
            workspacesByProject: [
                "p1": [Self.workspace("w1", branch: "main", isDefault: true), Self.workspace("w2", branch: "old", isHidden: true)]
            ], query: "")

        #expect(tree[0].projects[0].trailingText == "1 of 2 shown")
    }

    @Test func hiddenProjectReportsProjectHiddenAndDimsItsSubtree() {
        let tree = WorkspaceVisibilityTree.build(
            devices: [Self.mac], projects: [Self.project("p1", name: "harbor", isHidden: true)],
            workspacesByProject: ["p1": [Self.workspace("w1", branch: "main", isDefault: true), Self.workspace("w2", branch: "feature")]], query: "")

        let project = tree[0].projects[0]
        #expect(project.trailingText == "project hidden")
        #expect(project.isDimmed)
        #expect(project.workspaces.allSatisfy { $0.isDimmed })
        // Dimmed, not suppressed: the children keep their own flags and stay individually toggleable.
        #expect(project.workspaces.allSatisfy { $0.isChecked })
        #expect(project.workspaces.map(\.workspaceID) == ["w1", "w2"])
    }

    @Test func shownProjectSubtreeIsNotDimmed() {
        let tree = WorkspaceVisibilityTree.build(
            devices: [Self.mac], projects: [Self.project("p1", name: "harbor")],
            workspacesByProject: ["p1": [Self.workspace("w1", branch: "main", isDefault: true)]], query: "")

        #expect(tree[0].projects[0].isDimmed == false)
        #expect(tree[0].projects[0].workspaces.allSatisfy { !$0.isDimmed })
    }

    @Test func nonGitProjectIsOneFlatRowDrivingItsSingleWorkspace() {
        let tree = WorkspaceVisibilityTree.build(
            devices: [Self.mac], projects: [Self.project("p1", name: "notes", isGitRepo: false)],
            workspacesByProject: ["p1": [Self.workspace("w1", branch: "", isHidden: true, isDefault: true)]], query: "")

        let project = tree[0].projects[0]
        #expect(project.workspaces.isEmpty)
        #expect(project.isExpandable == false)
        #expect(project.trailingText == "")
        #expect(project.toggle == .workspace(workspaceID: "w1", isHidden: true))
        #expect(project.isChecked == false)
    }

    @Test func gitProjectRowTogglesTheProjectFlag() {
        let tree = WorkspaceVisibilityTree.build(
            devices: [Self.mac], projects: [Self.project("p1", name: "harbor")],
            workspacesByProject: ["p1": [Self.workspace("w1", branch: "main", isDefault: true)]], query: "")

        #expect(tree[0].projects[0].toggle == .project(isHidden: false))
        #expect(tree[0].projects[0].isExpandable)
    }

    @Test func workspaceMatchKeepsItsProjectAndDeviceAncestors() {
        let tree = WorkspaceVisibilityTree.build(
            devices: [Self.mac, Self.linux],
            projects: [Self.project("p1", name: "harbor"), Self.project("p2", name: "atlas", deviceID: "device-linux")],
            workspacesByProject: [
                "p1": [Self.workspace("w1", branch: "main", isDefault: true), Self.workspace("w2", branch: "lantern")],
                "p2": [Self.workspace("w3", branch: "main", isDefault: true)],
            ], query: "lantern")

        #expect(tree.map(\.deviceID) == ["device-mac"])
        #expect(tree[0].projects.map(\.projectID) == ["p1"])
        #expect(tree[0].projects[0].workspaces.map(\.workspaceID) == ["w2"])
    }

    @Test func projectMatchKeepsEveryChild() {
        let tree = WorkspaceVisibilityTree.build(
            devices: [Self.mac], projects: [Self.project("p1", name: "harbor"), Self.project("p2", name: "atlas")],
            workspacesByProject: [
                "p1": [Self.workspace("w1", branch: "main", isDefault: true), Self.workspace("w2", branch: "feature")],
                "p2": [Self.workspace("w3", branch: "main", isDefault: true)],
            ], query: "harbor")

        #expect(tree[0].projects.map(\.projectID) == ["p1"])
        #expect(tree[0].projects[0].workspaces.map(\.workspaceID) == ["w1", "w2"])
    }

    @Test func searchKeepsTheProjectCountOfTheWholeProject() {
        let tree = WorkspaceVisibilityTree.build(
            devices: [Self.mac], projects: [Self.project("p1", name: "harbor")],
            workspacesByProject: [
                "p1": [
                    Self.workspace("w1", branch: "main", isDefault: true), Self.workspace("w2", branch: "lantern"),
                    Self.workspace("w3", branch: "old", isHidden: true),
                ]
            ], query: "lantern")

        #expect(tree[0].projects[0].workspaces.map(\.workspaceID) == ["w2"])
        #expect(tree[0].projects[0].trailingText == "2 of 3 shown")
    }

    @Test func nonMatchingDeviceDropsOutWhileSearching() {
        let tree = WorkspaceVisibilityTree.build(
            devices: [Self.mac, Self.linux],
            projects: [Self.project("p1", name: "harbor"), Self.project("p2", name: "atlas", deviceID: "device-linux")],
            workspacesByProject: ["p1": [Self.workspace("w1", branch: "main", isDefault: true)], "p2": [Self.workspace("w2", branch: "main")]],
            query: "atlas")

        #expect(tree.map(\.deviceID) == ["device-linux"])
    }

    @Test func blankQueryReturnsTheWholeTree() {
        let tree = WorkspaceVisibilityTree.build(
            devices: [Self.mac], projects: [Self.project("p1", name: "harbor")],
            workspacesByProject: ["p1": [Self.workspace("w1", branch: "main", isDefault: true)]], query: "   ")

        #expect(tree[0].projects[0].workspaces.map(\.workspaceID) == ["w1"])
    }
}
