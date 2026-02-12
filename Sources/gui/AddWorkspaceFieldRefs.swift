import AppKit

@MainActor
final class AddWorkspaceAutoNameState {
    var lastAutoWorkspaceName: String = ""
}

struct AddWorkspaceFieldRefs {
    let projectID: String
    let isGitRepo: Bool
    let nameField: NSTextField
    let branchField: NSTextField?
    let autoNameState: AddWorkspaceAutoNameState?
}
