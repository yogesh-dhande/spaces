import Foundation
import spacesterminalcore

/// Profile-scoped filesystem layout for automation run artifacts. Each run owns a directory under the
/// profile's terminal root that holds the command's exit-code sentinel and the captured transcripts of any
/// coding-agent sessions the run spawned. Retention and automation deletion remove these directories.
public enum AutomationPaths {
    /// Root directory holding every run's artifacts: `<terminalRoot>/automations/runs`.
    public static func runsRootDirectory(fileManager: FileManager = .default) throws -> URL {
        let root = try TerminalServicePaths.terminalRootDirectory(fileManager: fileManager)
            .appendingPathComponent("automations", isDirectory: true)
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

    /// Destination for a captured attributed coding-agent transcript: `agent-<sessionID>.log`.
    public static func attributedSessionLogPath(runID: String, sessionID: String, fileManager: FileManager = .default) throws -> URL {
        try runDirectory(runID: runID, fileManager: fileManager).appendingPathComponent("agent-\(sessionID).log", isDirectory: false)
    }
}
