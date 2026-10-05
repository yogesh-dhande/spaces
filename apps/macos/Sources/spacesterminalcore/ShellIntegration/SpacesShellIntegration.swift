import Foundation

/// The generated, per-profile shell integration that keeps Spaces' `codex` wrapper first on PATH inside
/// Spaces terminals.
///
/// Codex 0.157+ shares one background app-server per `CODEX_HOME`, started with the first terminal's
/// environment, so every later `codex` TUI would report from the FIRST terminal's `SPACES_*` variables.
/// `codex --no-daemon` runs the server in-process instead. The wrapper (`bin/codex`) adds that flag.
///
/// A PATH entry set at launch is not enough: the user's startup files run AFTER Spaces' environment is
/// set, and they routinely prepend their own directories (a version manager's per-shell bin, where `codex`
/// lives). So each supported shell also gets a startup hook that moves the wrapper directory back to the
/// front before every prompt (see `SpacesShellIntegration+Launch.swift` for how each shell is wired).
///
/// Every terminal launch ensures the files are present and current (`prepared()`), writing only what is
/// missing or differs from this build and always atomically, so a launch never points a shell at a missing
/// file and never reads a half-written one. All absolute paths are embedded in the generated text rather
/// than passed through new environment variables.
public struct SpacesShellIntegration: Equatable, Sendable {
    public static let directoryName = "shell-integration"
    /// An empty file whose presence marks a directory as a Spaces wrapper directory. Wrappers skip every
    /// marked directory (not only their own) when they look for the real `codex`, and the daemon strips
    /// every marked directory from its own PATH.
    public static let wrapperMarkerFileName = ".spaces-codex-wrapper"
    static let wrapperName = "codex"

    public let rootDirectory: String

    public init(profileRoot: String) {
        rootDirectory = URL(fileURLWithPath: profileRoot, isDirectory: true).appendingPathComponent(Self.directoryName, isDirectory: true).path
    }

    public static func current() throws -> SpacesShellIntegration { SpacesShellIntegration(profileRoot: try SpacesProfile.current().rootDirectory) }

    /// The current profile's integration with its files ensured on disk. The single writer: a shell pointed
    /// at a missing startup file would silently skip the user's own rc files.
    public static func prepared() throws -> SpacesShellIntegration {
        let integration = try current()
        try integration.ensureInstalled()
        return integration
    }

    public var binDirectory: String { path("bin") }
    var wrapperPath: String { path("bin/\(Self.wrapperName)") }
    var markerPath: String { path("bin/\(Self.wrapperMarkerFileName)") }
    var zshDirectory: String { path("zsh") }
    var bashScriptPath: String { path("bash/spaces.bash") }
    /// A data directory for fish: fish sources `<XDG_DATA_DIRS entry>/fish/vendor_conf.d/*.fish` at startup.
    var fishDataDirectory: String { path("fish-data") }
    var fishScriptPath: String { path("fish-data/fish/vendor_conf.d/spaces.fish") }

    private func path(_ relative: String) -> String { URL(fileURLWithPath: rootDirectory, isDirectory: true).appendingPathComponent(relative).path }

    /// Writes each generated file that is missing or whose contents or mode differ from this build's; an
    /// identical file is left untouched, so a launch normally only reads. Safe to call concurrently.
    public func ensureInstalled() throws {
        let files: [(path: String, contents: String, permissions: Int)] = [
            (wrapperPath, SpacesShellIntegrationScripts.codexWrapper(), 0o755), (markerPath, "", 0o644),
            (zshDirectory + "/.zshenv", SpacesShellIntegrationScripts.zshenv(binDirectory: binDirectory), 0o644),
            (bashScriptPath, SpacesShellIntegrationScripts.bash(binDirectory: binDirectory), 0o644),
            (fishScriptPath, SpacesShellIntegrationScripts.fish(binDirectory: binDirectory), 0o644),
        ]
        for file in files where !Self.isCurrent(file.path, contents: file.contents, permissions: file.permissions) {
            try Self.writeAtomically(file.contents, to: file.path, permissions: file.permissions)
        }
    }

    private static func isCurrent(_ path: String, contents: String, permissions: Int) -> Bool {
        guard let data = FileManager.default.contents(atPath: path), data == Data(contents.utf8),
            let mode = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int
        else { return false }
        return mode == permissions
    }

    /// Temp file in the destination directory, permissions set, then `rename`: the destination is always
    /// either the previous complete file or the new complete file, with its final mode.
    private static func writeAtomically(_ contents: String, to path: String, permissions: Int) throws {
        let destination = URL(fileURLWithPath: path)
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try Data(contents.utf8).write(to: temporary)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            guard rename(temporary.path, path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// `path` without any entry whose directory holds the wrapper marker, or nil when nothing was removed.
    ///
    /// The daemon applies this to its own PATH: a daemon started from inside a Spaces terminal inherits the
    /// wrapper directory, and the Codex hook installer resolves `codex` from the daemon's PATH, so it must
    /// never find a wrapper there. Empty entries (the current directory) are kept as written.
    public static func pathRemovingWrapperDirectories(_ path: String?, fileManager: FileManager = .default) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let entries = path.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let kept = entries.filter { entry in entry.isEmpty || !fileManager.fileExists(atPath: entry + "/" + wrapperMarkerFileName) }
        return kept.count == entries.count ? nil : kept.joined(separator: ":")
    }
}
