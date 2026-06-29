import AppKit

@MainActor final class AddWorkspaceAutoNameState { var branchOptions: [String] = [] }

struct AddWorkspaceFieldRefs {
    let projectID: String
    let isGitRepo: Bool
    let branchModeSegmented: NSSegmentedControl?
    let existingBranchField: NSComboBox?
    let newBranchField: NSTextField?
    let baseBranchField: NSComboBox?
    let notesField: NSTextField?
    let autoNameState: AddWorkspaceAutoNameState?
    let createButton: NSButton
}
