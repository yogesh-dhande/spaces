import AppKit
import CoreGraphics
import Foundation

public struct DetectedWindow: Sendable {
    public let windowID: Int
    public let title: String?

    public init(windowID: Int, title: String?) {
        self.windowID = windowID
        self.title = title
    }
}

public final class CustomAppAdapter {
    public init() {}

    public func launchAndDetectWindow(bundleID: String, command: String, matchTitle: String?) -> DetectedWindow? {
        let before = Set(windows(bundleID: bundleID).map(\.windowID))
        runDetached(command: command)

        for _ in 0..<50 {
            let now = windows(bundleID: bundleID)
            if let newWindow = now.first(where: { !before.contains($0.windowID) }) {
                return newWindow
            }
            if let matchTitle, let matched = now.first(where: { ($0.title ?? "").localizedCaseInsensitiveContains(matchTitle) }) {
                return matched
            }
            if before.isEmpty, let first = now.first {
                return first
            }
            usleep(120_000)
        }

        return nil
    }

    public func windowExists(bundleID: String, windowID: Int?, titleFallback: String?) -> Bool {
        let now = windows(bundleID: bundleID)
        if let windowID, now.contains(where: { $0.windowID == windowID }) {
            return true
        }
        if let titleFallback {
            return now.contains(where: { ($0.title ?? "").localizedCaseInsensitiveContains(titleFallback) })
        }
        return false
    }

    public func detectWindow(bundleID: String, matchTitle: String?) -> DetectedWindow? {
        let now = windows(bundleID: bundleID)
        if let matchTitle, let matched = now.first(where: { ($0.title ?? "").localizedCaseInsensitiveContains(matchTitle) }) {
            return matched
        }
        return now.first
    }

    private func runDetached(command: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
    }

    private func windows(bundleID: String) -> [DetectedWindow] {
        // Use all windows (including minimized/off-screen) so show/hide can
        // reliably rediscover windows after a hide operation.
        guard let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let runningApps = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0.bundleIdentifier) })

        return raw.compactMap { info in
            guard let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber else {
                return nil
            }
            let pid = pid_t(pidNumber.intValue)
            guard runningApps[pid] == bundleID else {
                return nil
            }
            guard let winNumber = info[kCGWindowNumber as String] as? NSNumber else {
                return nil
            }
            let title = info[kCGWindowName as String] as? String
            return DetectedWindow(windowID: winNumber.intValue, title: title)
        }
    }
}
