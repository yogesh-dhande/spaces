import Foundation

public enum TerminalPerformance {
    /// Whether the DEBUG perf log is recording. Callers with metric inputs that are expensive to
    /// compute (e.g. re-encoding a payload just to measure its size) should check this before
    /// paying for them, since every log function below is a no-op when it is false.
    public static var isEnabled: Bool { ProcessInfo.processInfo.environment["DEBUG"] == "1" }

    public static func elapsedMS(since startedAt: Date) -> Int { max(Int(Date().timeIntervalSince(startedAt) * 1000), 0) }

    public static func logMetric(_ metric: String, target: String, elapsedMS: Int, success: Bool, detail: String = "") {
        guard isEnabled else { return }
        let suffix = detail.isEmpty ? "" : " \(detail)"
        logLine("spaces: perf metric=\(metric) target=\(target) success=\(success ? 1 : 0) elapsed_ms=\(elapsedMS)\(suffix)\n")
    }

    public static func logWorkspaceMetric(_ metric: String, workspaceID: String, target: String, elapsedMS: Int, success: Bool, detail: String = "") {
        guard isEnabled else { return }
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
