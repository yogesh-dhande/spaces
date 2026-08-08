import Foundation

public enum TerminalPerformance {
    /// Whether the DEBUG perf log is recording. Callers with metric inputs that are expensive to
    /// compute (e.g. re-encoding a payload just to measure its size) should check this before
    /// paying for them, since every log function below is a no-op when it is false.
    ///
    /// Resolved once per process rather than per access. As a computed property this read the whole
    /// process environment every time it was consulted, and it is consulted on the terminal's per-output
    /// path: the state broadcast guard reads it after `SpacesDeviceTerminalPerformanceLogger.isEnabled()`
    /// in an `||`, which does not short-circuit while the perf log is off — so the cheap check in front of
    /// it would have handed straight back to a full environment materialization. The serial terminal engine
    /// queue is saturated at roughly one core, so work on that path is charged against every session's
    /// output and keystrokes.
    ///
    /// The consequence is that exporting `DEBUG` after the process has started does not take effect, which
    /// matches how `SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH` and the trace flag already behave.
    public static let isEnabled: Bool = ProcessInfo.processInfo.environment["DEBUG"] == "1"

    public static func elapsedMS(since startedAt: Date) -> Int { max(Int(Date().timeIntervalSince(startedAt) * 1000), 0) }

    /// `detail` is `@autoclosure` so a disabled log never pays for it. Hot call sites build theirs by
    /// sorting and joining a metric attribute dictionary, which on the terminal's per-frame path costs
    /// more than the log line it would have produced.
    public static func logMetric(_ metric: String, target: String, elapsedMS: Int, success: Bool, detail: @autoclosure () -> String = "") {
        guard isEnabled else { return }
        let detail = detail()
        let suffix = detail.isEmpty ? "" : " \(detail)"
        logLine("spaces: perf metric=\(metric) target=\(target) success=\(success ? 1 : 0) elapsed_ms=\(elapsedMS)\(suffix)\n")
    }

    public static func logWorkspaceMetric(
        _ metric: String, workspaceID: String, target: String, elapsedMS: Int, success: Bool, detail: @autoclosure () -> String = ""
    ) {
        guard isEnabled else { return }
        let detail = detail()
        let suffix = detail.isEmpty ? "" : " \(detail)"
        logLine(
            "spaces: perf metric=\(metric) workspace=\(workspaceID) target=\(target) success=\(success ? 1 : 0) elapsed_ms=\(elapsedMS)\(suffix)\n")
    }

    public static func logLine(_ line: String) {
        guard isEnabled else { return }
        let stamped = "\(timestamp()) \(line)"
        FileHandle.standardError.write(Data(stamped.utf8))
        appendToPerfLog(stamped)
    }

    private static func timestamp() -> String {
        let now = Date()
        let ms = Int(now.timeIntervalSince1970 * 1000) % 1000
        return "\(Self.timeFormatter.string(from: now)).\(String(format: "%03d", ms))"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static func appendToPerfLog(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let fileManager = FileManager.default
        do {
            let directoryURL = try perfLogDirectory(fileManager: fileManager)
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let logURL = directoryURL.appendingPathComponent("perf.log", isDirectory: false)
            if !fileManager.fileExists(atPath: logURL.path) { _ = fileManager.createFile(atPath: logURL.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch { FileHandle.standardError.write(Data("spaces: failed to write perf log: \(error)\n".utf8)) }
    }

    private static func perfLogDirectory(fileManager: FileManager) throws -> URL {
        URL(fileURLWithPath: try SpacesProfile.current().runtimeDirectory, isDirectory: true)
    }
}
