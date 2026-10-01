/// A project created by a user-initiated create, with whether its configuration came from the
/// repository's `spaces.yaml`.
public struct CreatedProject: Sendable {
    public let project: ProjectRecord
    public let spacesYAMLImported: Bool

    public init(project: ProjectRecord, spacesYAMLImported: Bool) {
        self.project = project
        self.spacesYAMLImported = spacesYAMLImported
    }
}
