import AppKit

@MainActor final class WorkspaceFieldCache {
    static let shared = WorkspaceFieldCache()
    var cache: [Int: WorkspaceFieldRefs] = [:]
}
