import AppKit

@MainActor final class AddWorkspaceAutoNameState {
    var lastAutoWorkspaceName: String = ""
    var lastAutoDirName: String = ""
    var branchOptions: [String] = []
}

struct AddWorkspaceFieldRefs {
    let projectID: String
    let isGitRepo: Bool
    let branchModePopup: NSPopUpButton?
    let existingBranchField: NSComboBox?
    let newBranchField: NSTextField?
    let targetBranchField: NSComboBox?
    let nameField: NSTextField
    let directoryNameField: NSTextField?
    let tooltipField: NSTextField?
    let autoNameState: AddWorkspaceAutoNameState?
    let progressiveInputViews: [NSView]
    let createButton: NSButton
}
