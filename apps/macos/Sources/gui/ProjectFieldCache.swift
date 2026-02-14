import AppKit

@MainActor final class ProjectFieldCache {
    static let shared = ProjectFieldCache()
    var cache: [Int: ProjectFieldRefs] = [:]
}
