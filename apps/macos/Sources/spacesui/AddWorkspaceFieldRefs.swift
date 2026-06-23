import AppKit

@MainActor final class AddWorkspaceAutoNameState {
    var lastAutoWorkspaceName: String = ""
    var lastAutoDirName: String = ""
    var branchOptions: [String] = []
}

struct AddWorkspaceFieldRefs {
    let projectID: String
    let isGitRepo: Bool
    let branchModeSegmented: NSSegmentedControl?
    let existingBranchField: NSComboBox?
    let newBranchField: NSTextField?
    let baseBranchField: NSComboBox?
    let nameField: NSTextField
    let directoryNameField: NSTextField?
    let notesField: NSTextField?
    let autoNameState: AddWorkspaceAutoNameState?
    let progressiveInputViews: [NSView]
    let createButton: NSButton
    let customizeStack: NSView?
    let customizeButton: NSButton?
}
