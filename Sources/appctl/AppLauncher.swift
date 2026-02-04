import AppKit
import Foundation

public enum AppLauncherError: LocalizedError {
    case launchFailed(bundleID: String)

    public var errorDescription: String? {
        switch self {
        case let .launchFailed(bundleID):
            return "Failed to launch app with bundle id: \(bundleID)"
        }
    }
}

public final class AppLauncher {
    public init() {}

    public func ensureRunning(bundleID: String) throws {
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) {
            return
        }

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
                if error != nil {
                    // Keep behavior synchronous; polling below decides final success.
                }
            }
            if waitForApp(bundleID: bundleID) {
                return
            }
        }

        throw AppLauncherError.launchFailed(bundleID: bundleID)
    }

    public func activate(bundleID: String) throws {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
            throw AppLauncherError.launchFailed(bundleID: bundleID)
        }
        _ = app.activate()
    }

    private func waitForApp(bundleID: String, retries: Int = 30, delayMs: Int = 100) -> Bool {
        for _ in 0..<retries {
            if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) {
                return true
            }
            usleep(useconds_t(delayMs * 1000))
        }
        return false
    }
}
