import Foundation
import UIKit
import spacesterminalcore

/// App-level events for the on-device performance baseline: everything that is about the app as a whole
/// rather than one terminal session (`TerminalViewerModel` emits its own session-scoped events directly
/// through `SpacesDeviceTerminalPerformanceLogger`). Every event here uses `sessionID: "app"` and
/// `source: "ios-app"` so the Mac-side report script can tell app-level rows from terminal-level ones
/// without inspecting attributes.
///
/// Every function is a cheap, unconditional one-liner at its call site: `SpacesDeviceTerminalPerformanceLogger
/// .emit` is already a no-op boolean check when no log path is configured (which is every non-DEBUG build,
/// since `configureLoggerAtLaunch` below only ever runs under `#if DEBUG`), so nothing here needs its own
/// `#if DEBUG` guard or `isEnabled()` check beyond the ones already inside the logger and the battery
/// helpers.
@MainActor enum DevicePerformanceLog {
    /// Points the DEBUG performance logger at a file inside this app's own Documents container, so a
    /// device run can be pulled afterward without knowing the container path ahead of time (see
    /// `SpacesDeviceTerminalPerformanceLogger.configureDefaultLogPath`). Must run before anything else in
    /// the app touches the logger; called once from `SpacesMobileAppModel.init`, the earliest point in this
    /// app's own startup path. A no-op if `SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH` is set (a Mac-side
    /// test harness setting the environment before launch keeps final say). Also a no-op inside the
    /// unit-test host: a device log there is never read, and the synchronous per-event file write adds
    /// main-actor work that shifts timing inside the viewer model's test seams.
    static func configureLoggerAtLaunch() {
        #if DEBUG
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
            guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let logURL = documentsURL.appendingPathComponent("perf", isDirectory: true).appendingPathComponent("device-perf.jsonl")
            SpacesDeviceTerminalPerformanceLogger.configureDefaultLogPath(logURL.path)
        #endif
    }

    /// Marks process launch. `build`/`ios_version`/`device_model` describe the hardware and build a
    /// baseline run is being measured on; the report script groups runs by them.
    static func appLaunch() {
        var attributes = batteryAttributes()
        attributes["build"] = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        attributes["ios_version"] = UIDevice.current.systemVersion
        attributes["device_model"] = deviceModelIdentifier()
        emit(name: "app_launch", attributes: attributes)
        emitBatterySample()
    }

    /// Marks a scene-phase transition (`RootTabView`'s `onChange(of: scenePhase)`). `openTerminal` records
    /// whether a terminal detail route was on screen at the moment of the transition, which is what makes
    /// "background with an open terminal" distinguishable from "background from the list" in the baseline.
    static func sceneChanged(phase: String, openTerminal: Bool) {
        var attributes = batteryAttributes()
        attributes["phase"] = phase
        attributes["open_terminal"] = openTerminal ? "1" : "0"
        emit(name: "app_scene_phase", attributes: attributes)
        emitBatterySample()
        // The process can suspend immediately after this transition, before the queued device-log write
        // above drains on its own; draining it here is what keeps the last event of a run on disk.
        if phase == "background" { SpacesDeviceTerminalPerformanceLogger.flush() }
    }

    /// Anchors an overview refresh attempt (`SpacesMobileAppModel.performRefresh`). Returns the uptime
    /// stamp `overviewRefreshEnd` needs for `elapsedMS`; uptime rather than wall-clock so a refresh that
    /// straddles a device sleep is not measured as artificially slow.
    static func overviewRefreshBegin() -> UInt64 {
        emit(name: "overview_refresh_begin")
        return DispatchTime.now().uptimeNanoseconds
    }

    /// Closes out the refresh `overviewRefreshBegin` opened. `count` is the number of terminal session
    /// rows in the overview this refresh accepted (nil when the refresh failed and accepted none).
    static func overviewRefreshEnd(beganAtUptimeNanoseconds: UInt64, count: Int?, success: Bool, error: String?) {
        var attributes = ["success": success ? "1" : "0"]
        if let error { attributes["error"] = sanitized(error) }
        emit(name: "overview_refresh_end", elapsedMS: elapsedMS(sinceUptimeNanoseconds: beganAtUptimeNanoseconds), count: count, attributes: attributes)
    }

    /// Captures the "Connection Error" alert's transition from absent to shown (`SpacesMobileAppModel
    /// .errorMessage`'s `didSet`), with everything cheap that explains it: the message itself, how long
    /// refreshes had been failing before the alert fired, whether a terminal was open at the time, and how
    /// many hosts the active device could be reached at. The cached endpoint host `SpacesDeviceAPIClient
    /// .currentResolvedHost()` reports is deliberately not included: that read is async, and folding it in
    /// would turn this synchronous `didSet` into one that races the alert it is describing.
    static func connectionErrorAlert(message: String, refreshFailureStreakSeconds: Double?, openTerminal: Bool, hostCount: Int) {
        var attributes = ["message": sanitized(message), "open_terminal": openTerminal ? "1" : "0", "host_count": String(hostCount)]
        if let refreshFailureStreakSeconds { attributes["refresh_failure_streak"] = String(format: "%.1f", refreshFailureStreakSeconds) }
        emit(name: "connection_error_alert", attributes: attributes)
    }

    /// Subscribes to `ProcessInfo.thermalStateDidChangeNotification` for the app's lifetime. Owned by
    /// `SpacesMobileAppModel` (which holds the returned token strongly) rather than started implicitly,
    /// so there is exactly one subscription regardless of how many models exist in a test process. Returns
    /// the inert token instead of registering when the logger is disabled, so a build with no log path
    /// configured keeps no notification subscription running for nobody to read.
    static func observeThermalStateChanges() -> any NSObjectProtocol {
        guard SpacesDeviceTerminalPerformanceLogger.isEnabled() else { return inertObserverToken() }
        return NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in emit(name: "thermal_state_change", attributes: ["thermal_state": thermalStateName(ProcessInfo.processInfo.thermalState)]) }
        }
    }

    /// A non-nil `NSObjectProtocol` token with no `NotificationCenter` subscription behind it, for a test
    /// construction path that needs `SpacesMobileAppModel.thermalStateObserverToken` to hold something
    /// without registering (and leaking) a real observer per test instance.
    static func inertObserverToken() -> any NSObjectProtocol { NSObject() }

    // MARK: - Battery

    /// Emits a standalone `battery_sample` event, on top of whatever event already folded the same
    /// attributes into itself (`app_launch`, `app_scene_phase`, and the terminal-level events below all
    /// do). A single event name lets the report script build one battery-over-time series without having
    /// to know every event that happens to carry battery attributes.
    static func emitBatterySample() { emit(name: "battery_sample", attributes: batteryAttributes()) }

    /// `battery_level` (0.0-1.0), `battery_state`, `thermal_state`, `low_power`. Battery monitoring is
    /// enabled only once the logger itself is (`SpacesDeviceTerminalPerformanceLogger.isEnabled()`), so a
    /// build with no log path configured never turns it on. Cheap and idempotent once enabled, so every
    /// call site here can read this unconditionally rather than threading an "already enabled" flag
    /// through each of them.
    static func batteryAttributes() -> [String: String] {
        guard SpacesDeviceTerminalPerformanceLogger.isEnabled() else { return [:] }
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        return [
            "battery_level": String(device.batteryLevel), "battery_state": batteryStateName(device.batteryState),
            "thermal_state": thermalStateName(ProcessInfo.processInfo.thermalState),
            "low_power": ProcessInfo.processInfo.isLowPowerModeEnabled ? "1" : "0",
        ]
    }

    private static func batteryStateName(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .unplugged: return "unplugged"
        case .charging: return "charging"
        case .full: return "full"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "nominal"
        }
    }

    // MARK: - Shared helpers (also used by `TerminalViewerModel`'s own events)

    /// Uptime-based elapsed milliseconds, matching `SpacesDeviceTerminalPerformanceEvent
    /// .emittedUptimeNanoseconds`'s clock rather than wall-clock time: every timed event in this baseline
    /// (open-to-first-paint, connect-to-subscribe, and the app-level ones above) is measured within one
    /// live run and must not be inflated by a device sleep the wall clock would otherwise count.
    static func elapsedMS(sinceUptimeNanoseconds startUptimeNanoseconds: UInt64?) -> Int? {
        guard let startUptimeNanoseconds else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= startUptimeNanoseconds else { return 0 }
        return Int((now - startUptimeNanoseconds) / 1_000_000)
    }

    /// Strips newlines from an error/alert message before it becomes a JSONL attribute value, so one log
    /// line stays one line no matter what the underlying error's `localizedDescription` contains.
    static func sanitized(_ text: String) -> String { text.replacingOccurrences(of: "\n", with: " ") }

    private static func emit(name: String, elapsedMS: Int? = nil, count: Int? = nil, attributes: [String: String] = [:]) {
        SpacesDeviceTerminalPerformanceLogger.emit(
            .init(sessionID: "app", source: "ios-app", name: name, elapsedMS: elapsedMS, count: count, attributes: attributes))
    }

    /// The device model identifier (e.g. `iPhone15,3`), read from `uname(2)`'s `machine` field the same
    /// way every other iOS device-identification snippet does, since `UIDevice.current.model` only ever
    /// reports the generic "iPhone"/"iPad".
    private static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { rawBuffer in
            let data = Data(rawBuffer)
            let nullIndex = data.firstIndex(of: 0) ?? data.count
            return String(data: data[..<nullIndex], encoding: .utf8) ?? ""
        }
    }
}
