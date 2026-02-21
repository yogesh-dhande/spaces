import AppKit

@MainActor final class AddWorkspaceAutoNameState {
    var lastAutoWorkspaceName: String = ""
    var lastAutoDirName: String = ""
}

struct AddWorkspaceFieldRefs {
    let projectID: String
    let isGitRepo: Bool
    let targetBranchField: NSComboBox?
    let nameField: NSTextField
    let directoryNameField: NSTextField?
    let branchField: NSTextField?
    let tooltipField: NSTextField?
    let autoNameState: AddWorkspaceAutoNameState?
    let progressiveInputViews: [NSView]
    let createButton: NSButton
}
