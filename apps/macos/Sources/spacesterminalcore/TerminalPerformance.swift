import Foundation

public enum TerminalPerformance {
    public static func elapsedMS(since startedAt: Date) -> Int { max(Int(Date().timeIntervalSince(startedAt) * 1000), 0) }

    public static func logMetric(_ metric: String, target: String, elapsedMS: Int, success: Bool, detail: String = "") {
        guard ProcessInfo.processInfo.environment["DEBUG"] == "1" else { return }
        let suffix = detail.isEmpty ? "" : " \(detail)"
        logLine("spaces: perf metric=\(metric) target=\(target) success=\(success ? 1 : 0) elapsed_ms=\(elapsedMS)\(suffix)\n")
    }

    public static func logWorkspaceMetric(_ metric: String, workspaceID: String, target: String, elapsedMS: Int, success: Bool, detail: String = "") {
        guard ProcessInfo.processInfo.environment["DEBUG"] == "1" else { return }
        let suffix = detail.isEmpty ? "" : " \(detail)"
        logLine(
            "spaces: perf metric=\(metric) workspace=\(workspaceID) target=\(target) success=\(success ? 1 : 0) elapsed_ms=\(elapsedMS)\(suffix)\n")
    }

    public static func logLine(_ line: String) {
        guard ProcessInfo.processInfo.environment["DEBUG"] == "1" else { return }
        fputs(line, stderr)
        appendToPerfLog(line)
    }

    private static func appendToPerfLog(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let fileManager = FileManager.default
        do {
            let directoryURL = try perfLogDirectory(fileManager: fileManager)
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let logURL = directoryURL.appendingPathComponent("perf.log", isDirectory: false)
            if !fileManager.fileExists(atPath: logURL.path) { fileManager.createFile(atPath: logURL.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch { fputs("spaces: failed to write perf log: \(error)\n", stderr) }
    }

    private static func perfLogDirectory(fileManager: FileManager) throws -> URL {
        if let override = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return try TerminalPlatformDirectories.defaultRuntimeDirectory(fileManager: fileManager)
    }
}
