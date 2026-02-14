import AppKit

@MainActor final class AddProjectFieldCache {
    static let shared = AddProjectFieldCache()
    var cache: [Int: AddProjectFieldRefs] = [:]
}
