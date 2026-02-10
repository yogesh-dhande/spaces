import AppKit

@MainActor
final class AddWorkspaceFieldCache {
    static let shared = AddWorkspaceFieldCache()
    var cache: [Int: AddWorkspaceFieldRefs] = [:]
}
