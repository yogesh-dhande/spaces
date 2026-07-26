import Foundation

/// `DEBUG=1`-gated stderr trace of one device's connection transitions: subscribe attempts and their
/// outcomes, dropped streams, offline transitions, armed and user-initiated retries, and the
/// reachability watchdog's decisions. Uses the same mechanism and `spaces: ` prefix as the
/// background-refresh failure log, and the daemon's `key=value` field style.
///
/// Transitions only. A device that is connected and healthy is silent, and nothing on this path may
/// log per pushed overview — the remote daemon pushes one on every database change it makes.
enum DeviceLinkTrace {
    static func log(deviceID: String, event: String, detail: String? = nil) {
        guard ProcessInfo.processInfo.environment["DEBUG"] == "1" else { return }
        // A detail's value can be a free-form error description containing spaces, so it is always the
        // tail of the line and every fixed field precedes it.
        fputs("spaces: device_link device=\(deviceID) event=\(event)\(detail.map { " \($0)" } ?? "")\n", stderr)
    }
}
