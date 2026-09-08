import Darwin
import Foundation

/// Appends `lane_marker` events into the same JSONL file the app writes its own performance events to
/// (`SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH` / `<run root>/device-perf.jsonl`), so the baseline
/// report reads one stream instead of needing to merge two files. The line shape matches
/// `SpacesDeviceTerminalPerformanceEvent` (spacesterminalcore) closely enough for the report to parse it
/// the same way, but this UI test target does not link against that package product, so the shape is
/// reproduced by hand here rather than reusing the type.
///
/// The UI test runner process (this XCTest bundle, running host-side against the simulator) and the
/// app-under-test process both append to this same path concurrently. Each write opens the file with
/// `O_APPEND` and closes it immediately rather than holding a long-lived file handle: `O_APPEND` makes
/// each `write(2)` atomic at the kernel level, so lines from the two processes interleave cleanly instead
/// of one process's partial write clobbering the other's.
enum BaselineLaneMarkers {
    /// Writes one `lane_marker` line. `profile`, `scenario`, and `marker` always land in `attributes`;
    /// `extraAttributes` carries whatever the scenario needs on top (`iteration`, `cycle`, `burst`,
    /// `index`, `direction`, ...). All attribute values are strings, matching
    /// `SpacesDeviceTerminalPerformanceEvent.attributes` on the app side.
    static func write(marker: String, profile: String, scenario: String, extraAttributes: [String: String] = [:], perfLogPath: String) {
        var attributes = extraAttributes
        attributes["profile"] = profile
        attributes["scenario"] = scenario
        attributes["marker"] = marker

        let payload: [String: Any] = [
            "sessionID": "lane", "source": "ios-uitest", "name": "lane_marker", "emittedAt": isoTimestamp(from: Date()),
            "emittedUptimeNanoseconds": DispatchTime.now().uptimeNanoseconds, "attributes": attributes,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        appendLine(data, to: perfLogPath)
    }

    /// ISO8601 with milliseconds, UTC (`yyyy-MM-ddTHH:mm:ss.SSSZ`), matching the format
    /// `GhosttyRemoteSessionStateTimestamp.string(from:)` produces for the app's own performance events.
    private static func isoTimestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private static func appendLine(_ data: Data, to path: String) {
        var line = data
        line.append(0x0A)
        let fileDescriptor = path.withCString { cPath in open(cPath, O_WRONLY | O_APPEND | O_CREAT, 0o644) }
        guard fileDescriptor >= 0 else { return }
        defer { close(fileDescriptor) }
        line.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            _ = Darwin.write(fileDescriptor, baseAddress, buffer.count)
        }
    }
}
