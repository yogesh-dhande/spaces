import Dispatch
import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

public struct SpacesDeviceTerminalPerformanceEvent: Codable, Equatable, Sendable {
    public let sessionID: String
    public let source: String
    public let name: String
    public let emittedAt: String
    public let emittedUptimeNanoseconds: UInt64
    public let elapsedMS: Int?
    public let count: Int?
    public let attributes: [String: String]

    public init(
        sessionID: String, source: String, name: String, emittedAt: String = GhosttyRemoteSessionStateTimestamp.string(from: Date()),
        emittedUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds, elapsedMS: Int? = nil, count: Int? = nil,
        attributes: [String: String] = [:]
    ) {
        self.sessionID = sessionID
        self.source = source
        self.name = name
        self.emittedAt = emittedAt
        self.emittedUptimeNanoseconds = emittedUptimeNanoseconds
        self.elapsedMS = elapsedMS
        self.count = count
        self.attributes = attributes
    }
}

public enum SpacesDeviceTerminalPerformanceLogger {
    public static let environmentKey = "SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH"

    /// Resolved once, the first time this enum is touched, rather than per call. `ProcessInfo.processInfo
    /// .environment` materializes the *entire* process environment dictionary on every access; reading it
    /// as a per-call default argument here used to run on every terminal output tick and measured at
    /// 70-80% of the serial terminal-engine queue's CPU while the logger was switched off (#332). Because
    /// this is a `static let`, exporting the environment variable after the process has already started
    /// has no effect on that process — the same one-time-read behavior as `ghosttyEmbeddedSessionTraceEnabled`
    /// in GhosttyEmbeddedSessionHost.swift.
    private static let resolvedLogPathAtLaunch: String? = resolvedLogPath(environment: ProcessInfo.processInfo.environment)

    /// Fallback used only when the environment variable above resolved to nil. A physical iOS device's
    /// app-container path is not known to whatever launches the process (there is no equivalent of a Mac
    /// test harness exporting the environment variable before `main` runs), so the iOS app supplies its
    /// own default from inside its own launch path via `configureDefaultLogPath` instead. `nonisolated
    /// (unsafe)` because it is written once, before any concurrent `emit` call can read it (see that
    /// function's doc comment), the same accepted-risk pattern used elsewhere in this codebase for
    /// set-once-at-launch global state (e.g. `SpacesApp.appDelegate`).
    nonisolated(unsafe) private static var defaultLogPath: String?

    /// Sets the log path `emit` uses when `SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH` is unset. Must be
    /// called before the first `emit`/`isEnabled()` call in the process, exactly like exporting the
    /// environment variable itself has no effect once the process has started: `resolvedLogPathAtLaunch`
    /// is a `static let` resolved on first touch, and this only ever backstops it, so a call after logging
    /// has already been observed as disabled will not retroactively enable it. The environment variable
    /// always wins when both are present, which is what lets a Mac-side test harness override an iOS
    /// build's compiled-in default.
    public static func configureDefaultLogPath(_ path: String) { defaultLogPath = path }

    #if DEBUG
        /// Undoes `configureDefaultLogPath` for a test that set it: the path is process-global, so without
        /// this every later test in the same process would keep writing a log nobody reads.
        static func resetDefaultLogPathForTesting() {
            flush()
            defaultLogPath = nil
        }
    #endif

    /// A disabled logger costs exactly this boolean check plus one already-resolved static read: no
    /// environment lookup happens per call, and `defaultLogPath` is a plain static var rather than
    /// anything that re-reads the environment.
    public static func isEnabled() -> Bool { resolvedLogPathAtLaunch != nil || defaultLogPath != nil }

    #if DEBUG
        /// Test-only interception point, consulted ahead of the normal file path so a suite can assert on
        /// emitted events without configuring a log file at all. Compiled out of release builds; never
        /// read or written outside `emit` and the tests that set it, which is the same set-before-use
        /// discipline `defaultLogPath` above relies on for its own `nonisolated(unsafe)`.
        nonisolated(unsafe) static var sinkForTesting: ((SpacesDeviceTerminalPerformanceEvent) -> Void)?
    #endif

    /// `event` is `@autoclosure` so a disabled logger never constructs the event (or evaluates whatever
    /// attribute dictionary a caller built inline to pass into it).
    ///
    /// The write itself splits by which path is active, because the two paths have opposite constraints:
    /// - The environment-configured path (`resolvedLogPathAtLaunch`) belongs to a Mac-side lane
    ///   (`e2e_mobile_latency.sh`, `e2e_terminal_latency.sh`, `profile_built_in_terminal.sh`) that reads the
    ///   file only after the process under measurement has already terminated, so anything still sitting on
    ///   `writeQueue` at that point would be silently lost; those lanes are not on the main-actor/per-frame
    ///   paths this logger exists to avoid perturbing, so writing inline costs them nothing they measure.
    /// - The device default path (`defaultLogPath`) is written from those measured paths, and the Mac-side
    ///   puller only reads it seconds after the run's last event, long after `writeQueue` has drained on its
    ///   own, so it keeps the queue.
    public static func emit(_ event: @autoclosure () -> SpacesDeviceTerminalPerformanceEvent) {
        #if DEBUG
            if let sinkForTesting {
                sinkForTesting(event())
                return
            }
        #endif
        // Path first, event second: with no path configured (every release build, and every daemon
        // without the lane variable) this returns before the autoclosure runs, so the disabled logger
        // never allocates an event or formats a timestamp on the hot paths that call it.
        guard let logPath = resolvedLogPathAtLaunch ?? defaultLogPath else { return }
        // The event is forced here, on the caller, so its attributes reflect the moment `emit` was called.
        let resolvedEvent = event()
        if resolvedLogPathAtLaunch != nil {
            // Never rotates: an environment-configured run is a single bounded lane invocation, not an
            // unattended install, so there is no unbounded growth to guard against, and rotating would
            // silently drop the run's earliest samples from the lane's summary.
            appendJSONLine(resolvedEvent, to: logPath, maximumBytes: nil)
            return
        }
        writeQueue.async {
            appendJSONLine(resolvedEvent, to: logPath, maximumBytes: maximumLogFileBytes)
        }
    }

    /// Backs only the device default path (`defaultLogPath`): `emit`'s callers there are the main actor and
    /// the per-frame terminal-flush path this logger measures, so writing inline (directory creation, JSON
    /// encode, stat, open/write/close) would perturb the first-paint and render latencies it exists to
    /// record. Routing every such write through this single serial queue moves that cost off the caller
    /// and, because it is the only writer, also replaces the `NSLock` a previous version of this file used
    /// to protect the rotation-then-write sequence from concurrent callers. A plain serial queue is enough,
    /// with no batching buffer, because each write is one small JSON line at `.utility` QoS and nothing on
    /// the phone reads the log file until the run is over: there is no reader to contend with and nothing
    /// worth batching for. The environment-configured path bypasses this queue entirely (see `emit`).
    /// Internal (not private), like `appendJSONLine` below, so `SpacesDeviceTerminalPerformanceLoggerTests`
    /// can dispatch onto it directly and exercise the same serialization `emit` relies on.
    internal static let writeQueue = DispatchQueue(label: "dev.usespaces.device-performance-log", qos: .utility)

    /// Waits for every write enqueued on `writeQueue` before this call to drain. Cheap and safe to call
    /// unconditionally: on the environment-configured path the queue is never used (writes are already
    /// inline), and on the device path it is meant only for lifecycle boundaries off the measured paths
    /// (an app backgrounding, or a test asserting on the log file right after `emit`), never for the
    /// measured paths themselves. The on-device runner never needs it otherwise: `writeQueue` drains
    /// continuously as events are emitted during the run, and the Mac-side puller reads the file seconds
    /// after the run's last event, long after the queue has drained on its own.
    public static func flush() { writeQueue.sync {} }

    private static func resolvedLogPath(environment: [String: String]) -> String? {
        let rawValue = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawValue, !rawValue.isEmpty else { return nil }
        return rawValue
    }

    /// Above this size, the next append rotates the current file to `<path>.1` (replacing any older one)
    /// and starts fresh, so an unattended DEBUG run cannot grow the on-device log without bound between
    /// baseline pulls. One rolled-over generation is enough: the Mac-side runner pulls the file after each
    /// run, well under the size a single run reaches even at the session flush rate.
    private static let maximumLogFileBytes = 8 * 1024 * 1024

    /// Appends one JSON line to `path`, rotating first when the append would grow the file past
    /// `maximumBytes`. Internal (not private) and parameterized on the threshold, rather than always using
    /// `maximumLogFileBytes`, so `SpacesDeviceTerminalPerformanceLoggerTests` can drive rotation with a few
    /// short lines instead of writing 8 MB of fixture data through it. Not synchronized internally: `emit`
    /// only ever reaches this through the single serial `writeQueue` above, so its calls never overlap; a
    /// test that calls this directly from multiple threads (rather than through `emit`) is responsible for
    /// its own serialization, the same way `writeQueue` provides it in production.
    internal static func appendJSONLine<T: Encodable>(_ value: T, to path: String, maximumBytes: Int?) {
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(value)
            data.append(0x0A)
            if let maximumBytes { rotateIfNeeded(path: url.path, incomingByteCount: data.count, maximumBytes: maximumBytes) }

            let fileDescriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
            guard fileDescriptor >= 0 else { return }
            defer { close(fileDescriptor) }

            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var bytesRemaining = rawBuffer.count
                var offset = 0
                while bytesRemaining > 0 {
                    let written = write(fileDescriptor, baseAddress.advanced(by: offset), bytesRemaining)
                    if written < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    bytesRemaining -= written
                    offset += written
                }
            }
        } catch {}
    }

    /// Renames `path` to `<path>.1` (replacing any existing one there) once the file already on disk plus
    /// the line about to be appended would exceed `maximumBytes`. A no-op the first time (nothing on disk
    /// yet) and on every ordinary append after that: one `stat` per append is negligible next to the write
    /// syscalls `appendJSONLine` already pays, so this needs no separate size tracking in memory.
    private static func rotateIfNeeded(path: String, incomingByteCount: Int, maximumBytes: Int) {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: path), let currentSize = (attributes[.size] as? Int) else { return }
        guard currentSize + incomingByteCount > maximumBytes else { return }
        let rotatedPath = path + ".1"
        try? fileManager.removeItem(atPath: rotatedPath)
        try? fileManager.moveItem(atPath: path, toPath: rotatedPath)
    }
}
