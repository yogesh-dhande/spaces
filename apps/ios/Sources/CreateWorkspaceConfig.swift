import Foundation

/// The fields that describe a workspace to create, bundled so `SpacesDeviceAPIClient.createWorkspace`
/// takes one value instead of a five-parameter argument list that mirrors the wire request's own fields.
struct CreateWorkspaceConfig: Sendable {
    var projectID: String
    var branch: String?
    var baseBranch: String?
    var directoryName: String?
    var allowExistingBranchReuse: Bool

    init(projectID: String, branch: String?, baseBranch: String?, directoryName: String?, allowExistingBranchReuse: Bool) {
        self.projectID = projectID
        self.branch = branch
        self.baseBranch = baseBranch
        self.directoryName = directoryName
        self.allowExistingBranchReuse = allowExistingBranchReuse
    }
}
