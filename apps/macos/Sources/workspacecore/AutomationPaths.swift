import Foundation
import spacesterminalcore

/// Profile-scoped filesystem layout for automation run artifacts. Each run owns a directory under the
/// profile's terminal root that holds the command's exit-code sentinel. A run's transcripts are not copied
/// here: its terminal sessions survive in their own directories until the run is pruned, and those are what
/// the Runs tab replays. Retention and automation deletion remove these directories.
public enum AutomationPaths {
    /// Root directory holding every run's artifacts: `<terminalRoot>/automations/runs`.
    public static func runsRootDirectory(fileManager: FileManager = .default) throws -> URL {
        let root = try TerminalServicePaths.terminalRootDirectory(fileManager: fileManager).appendingPathComponent("automations", isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
        return root
    }

    /// Artifacts directory for a single run: `<runsRoot>/<runID>`.
    public static func runDirectory(runID: String, fileManager: FileManager = .default) throws -> URL {
        try runsRootDirectory(fileManager: fileManager).appendingPathComponent(runID, isDirectory: true)
    }

    /// Creates (if needed) and returns the run's artifacts directory.
    @discardableResult public static func ensureRunDirectory(runID: String, fileManager: FileManager = .default) throws -> URL {
        let directory = try runDirectory(runID: runID, fileManager: fileManager)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Sentinel file the wrapped command writes its exit code into, read back when the session ends.
    public static func exitCodePath(runID: String, fileManager: FileManager = .default) throws -> URL {
        try runDirectory(runID: runID, fileManager: fileManager).appendingPathComponent("exitcode", isDirectory: false)
    }
}
