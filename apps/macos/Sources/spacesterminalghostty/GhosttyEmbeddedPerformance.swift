import Foundation

public enum GhosttyEmbeddedPerformance {
    public static func elapsedMS(since startedAt: Date) -> Int { max(Int(Date().timeIntervalSince(startedAt) * 1000), 0) }

    public static func logMetric(_ metric: String, target: String, elapsedMS: Int, success: Bool, detail: String = "") {
        guard ProcessInfo.processInfo.environment["DEBUG"] == "1" else { return }
        let suffix = detail.isEmpty ? "" : " \(detail)"
        fputs("spaces: perf metric=\(metric) target=\(target) success=\(success ? 1 : 0) elapsed_ms=\(elapsedMS)\(suffix)\n", stderr)
    }
}
