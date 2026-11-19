import Foundation

/// `stat(2) `, named apart from `SessionStoreFileSystem.stat` and the `stat` struct it would otherwise
/// be ambiguous with inside that class. Follows symlinks, so a symlinked store root is listed.
private func statFollowingLinks(_ path: String, _ info: inout Foundation.stat) -> Int32 { stat(path, &info) }

/// The file system calls store discovery makes, so a refresh pass can skip the ones whose answer cannot
/// have changed and tests can count what a pass touched.
///
/// With `remembersListings`, a directory is read only when its own modification time differs from the
/// last time it was read: creating, removing or renaming an entry changes it, appending to a file does
/// not. The caller still stats every file that can grow; `immutableFiles` names the ones that cannot
/// (a compressed Codex rollout is written once), whose recorded stat is returned without a system call.
final class SessionStoreFileSystem {
    struct Entry {
        let name: String
        let isDirectory: Bool
    }

    private struct Listing {
        let modifiedAt: Double
        let entries: [Entry]
    }

    private let remembersListings: Bool
    private var listings: [String: Listing] = [:]
    private var rememberedSources: [String: [AgentSessionSource]] = [:]
    /// Stats recorded by earlier passes for files that never change, by path.
    var immutableFiles: [String: AgentSessionFile] = [:]

    private(set) var filesStatted = 0
    private(set) var directoriesStatted = 0
    private(set) var directoriesListed = 0

    init(remembersListings: Bool = false) { self.remembersListings = remembersListings }

    func resetCounters() {
        filesStatted = 0
        directoriesStatted = 0
        directoriesListed = 0
    }

    func stat(_ url: URL, kind: AgentSessionFile.Kind) throws -> AgentSessionFile { try stat(path: url.path, kind: kind) }

    /// Path strings rather than URLs for the stores that walk thousands of files: building a `URL` per
    /// entry was most of the cost of a pass that otherwise only compares modification times.
    func stat(path: String, kind: AgentSessionFile.Kind) throws -> AgentSessionFile {
        if kind == .compressedTranscript, let known = immutableFiles[path] { return known }
        filesStatted += 1
        return try AgentSessionFile.stat(path: path, kind: kind)
    }

    /// The stat of `url`, or nil when it does not exist.
    func statIfPresent(_ url: URL) -> AgentSessionFile? {
        filesStatted += 1
        return try? AgentSessionFile.stat(url, kind: .metadata)
    }

    /// The visible entries of `directory`, or none when it does not exist. Throws when it exists but
    /// cannot be read, which is different from empty: the caller must not conclude its sessions are gone.
    func list(_ directory: URL) throws -> [Entry] { try list(path: directory.path) }

    func list(path: String) throws -> [Entry] {
        var info = Foundation.stat()
        directoriesStatted += 1
        guard statFollowingLinks(path, &info) == 0 else {
            let failure = errno
            listings[path] = nil
            rememberedSources[path] = nil
            if failure == ENOENT { return [] }
            throw AgentSessionReadError.cannotOpen(path)
        }
        let modifiedAt = Self.modificationTime(info)
        if remembersListings, let known = listings[path], known.modifiedAt == modifiedAt { return known.entries }

        let entries = try Self.readEntries(path)
        directoriesListed += 1
        if remembersListings {
            listings[path] = Listing(modifiedAt: modifiedAt, entries: entries)
            rememberedSources[path] = nil
        }
        return entries
    }

    /// Sources a store built from `path`'s entries, valid while the directory's listing is unchanged: the
    /// call must follow the `list` that returned the entries (a re-read forgets them). A store remembers
    /// only sources made of immutable files, so a pass over an unchanged directory skips parsing every name.
    func rememberedSources(inDirectory path: String) -> [AgentSessionSource]? { rememberedSources[path] }

    func remember(_ sources: [AgentSessionSource], inDirectory path: String) { if remembersListings { rememberedSources[path] = sources } }

    private static func modificationTime(_ info: Foundation.stat) -> Double {
        #if os(Linux)
            let modified = info.st_mtim
        #else
            let modified = info.st_mtimespec
        #endif
        return Double(modified.tv_sec) + Double(modified.tv_nsec) / 1_000_000_000
    }

    /// `readdir` with the entry type it already carries, so no per-entry stat is needed. Symlinks are
    /// reported as non-directories and never followed.
    private static func readEntries(_ path: String) throws -> [Entry] {
        guard let directory = opendir(path) else { throw AgentSessionReadError.cannotOpen(path) }
        defer { closedir(directory) }
        var entries: [Entry] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name.hasPrefix(".") { continue }
            var isDirectory = entry.pointee.d_type == UInt8(DT_DIR)
            if entry.pointee.d_type == UInt8(DT_UNKNOWN) {
                var info = Foundation.stat()
                isDirectory = lstat(path + "/" + name, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            }
            entries.append(Entry(name: name, isDirectory: isDirectory))
        }
        return entries
    }
}
