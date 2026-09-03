import Dispatch
import Foundation
import Testing
import spacesterminalcore

@testable import spacesdevicecore

/// Covers the terminal state stream's liveness watch: a transport that stays open while carrying
/// nothing is reported as a stall so the owner can reconnect, and the daemon's keepalive frames are
/// what keep an idle terminal's stream from being reported that way.
@Suite struct SpacesDeviceAPIStateStreamClientTests {
    private static let fingerprint = "SHA256:" + String(repeating: "c", count: 64)
    private static let port = 47_847
    /// Short enough to keep the suite fast, long enough that a loaded machine cannot mistake normal
    /// scheduling delay for silence. The tests poll asynchronously rather than with `Thread.sleep`, so
    /// they never park a cooperative-pool thread (see `SpacesBlockingIOThread`).
    private static let silenceTimeout: TimeInterval = 0.8
    /// An upper bound for a starved CI runner, not a measurement: the stall is reported after
    /// `silenceTimeout` and the wait returns the moment it is, so a generous ceiling costs a passing run
    /// nothing and keeps a runner that pauses the process for tens of seconds (CI run 33789498420 stalled
    /// every suite in flight for ~30 s) from reading a late report as a missing one.
    private static let stallReportCeiling: TimeInterval = 30

    /// The bug this fix is about: the peer keeps the socket open but nothing arrives, so without a
    /// liveness watch the client sits on a dead stream forever.
    @Test func silenceAfterAPayloadReportsAStallAndReleasesTheConnection() async throws {
        let dialer = StreamingConnectionDialer()
        let events = StreamRecorder()
        let client = try SpacesDeviceAPIStateStreamClient(
            request: Self.request(), resolver: Self.makeResolver(dialer: dialer), silenceTimeout: Self.silenceTimeout,
            onEvent: { events.recordEvent($0) }, onDisconnect: { events.recordDisconnect($0) })
        try client.start(timeoutSeconds: 1)

        let connection = try #require(dialer.connections().first)
        connection.deliverPayload(Self.payload())
        #expect(await events.waitForEvents(count: 1, timeout: 2))

        #expect(await events.waitForDisconnect(timeout: Self.stallReportCeiling))
        guard case SpacesDeviceAPIRequestClientError.streamStalled = try #require(events.disconnectError()) else {
            Issue.record("Expected streamStalled, got \(String(describing: events.disconnectError()))")
            return
        }
        #expect(connection.isCancelled())
    }

    /// The daemon side of the fix: empty keepalive lines carry no state and never reach `onEvent`, but
    /// they are bytes off the wire, so an idle terminal's stream stays connected indefinitely.
    ///
    /// Both the keepalive producer and the observation of its effect run on a dedicated thread rather
    /// than the cooperative pool: the watchdog itself now runs on a real thread precisely so it survives
    /// pool starvation, so a `Task.sleep`-driven producer that pool starvation pauses for longer than
    /// `silenceTimeout` would read as silence and cause a false stall. The result is captured immediately
    /// after the last keepalive, while keepalives are still fresh, because the moment they stop the
    /// stream legitimately begins its silence countdown.
    @Test func keepaliveFramesKeepAnIdleStreamConnected() async throws {
        let dialer = StreamingConnectionDialer()
        let events = StreamRecorder()
        let client = try SpacesDeviceAPIStateStreamClient(
            request: Self.request(), resolver: Self.makeResolver(dialer: dialer), silenceTimeout: Self.silenceTimeout,
            onEvent: { events.recordEvent($0) }, onDisconnect: { events.recordDisconnect($0) })
        try client.start(timeoutSeconds: 1)
        defer { client.stop() }

        let connection = try #require(dialer.connections().first)
        let keepaliveInterval = Self.silenceTimeout / 4
        let result = KeepaliveObservationResult()
        SpacesBlockingIOThread.spawn(name: "spaces.test.stream-keepalive") {
            let deadline = Date().addingTimeInterval(Self.silenceTimeout * 3)
            while Date() < deadline {
                connection.deliverKeepalive()
                Thread.sleep(forTimeInterval: keepaliveInterval)
            }
            result.capture(disconnectCount: events.disconnectCount(), eventCount: events.eventCount(), cancelled: connection.isCancelled())
        }

        #expect(await result.waitForCompletion(timeout: Self.stallReportCeiling))
        let captured = try #require(result.captured())
        #expect(captured.disconnectCount == 0)
        #expect(captured.eventCount == 0)
        #expect(!captured.cancelled)
    }

    private static func request() -> SpacesDeviceAPIRequest {
        SpacesDeviceAPIRequest(
            command: .subscribe(SpacesDeviceTerminalSubscriptionRequest(sessionID: "session-1", clientID: nil)), authToken: nil, clientApp: nil)
    }

    private static func payload() -> GhosttyRemoteSessionStatePayload {
        GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: "state", emittedAt: GhosttyRemoteSessionStateTimestamp.string(from: Date()),
            sessionStateRevision: 1, sessionStateFlags: nil, screenStateRevision: nil, runtimeState: nil, attachmentSnapshot: nil, title: "zsh",
            workingDirectory: "/tmp", outputByteCount: 0)
    }

    private static func makeResolver(dialer: StreamingConnectionDialer) -> SpacesDeviceEndpointResolver {
        SpacesDeviceEndpointResolver(
            hosts: ["lan"], port: port, certificateFingerprint: fingerprint, activeHost: nil, onProvenHost: { _ in },
            connect: { _, _, _, _ in dialer.connect() }, plainTCPProbe: { _, _, _ in false })
    }
}

/// Collects what the stream reported, from whichever queue reported it.
private final class StreamRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [GhosttyRemoteSessionStatePayload] = []
    private var disconnects: [(any Error)?] = []

    func recordEvent(_ payload: GhosttyRemoteSessionStatePayload) {
        lock.lock()
        events.append(payload)
        lock.unlock()
    }

    func recordDisconnect(_ error: (any Error)?) {
        lock.lock()
        disconnects.append(error)
        lock.unlock()
    }

    func eventCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }

    func disconnectCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return disconnects.count
    }

    func disconnectError() -> (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return disconnects.first ?? nil
    }

    func waitForEvents(count: Int, timeout: TimeInterval) async -> Bool { await waitUntil(timeout: timeout) { self.eventCount() >= count } }

    func waitForDisconnect(timeout: TimeInterval) async -> Bool { await waitUntil(timeout: timeout) { self.disconnectCount() > 0 } }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

/// Holds the keepalive test's captured result, set once from the dedicated thread that drives the
/// keepalive loop and read by the async test body polling for it.
private final class KeepaliveObservationResult: @unchecked Sendable {
    struct Captured {
        let disconnectCount: Int
        let eventCount: Int
        let cancelled: Bool
    }

    private let lock = NSLock()
    private var value: Captured?

    func capture(disconnectCount: Int, eventCount: Int, cancelled: Bool) {
        lock.lock()
        value = Captured(disconnectCount: disconnectCount, eventCount: eventCount, cancelled: cancelled)
        lock.unlock()
    }

    func captured() -> Captured? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func waitForCompletion(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if captured() != nil { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return captured() != nil
    }
}

private final class StreamingConnectionDialer: @unchecked Sendable {
    private let lock = NSLock()
    private var created: [StreamingFakeConnection] = []

    func connect() -> any SpacesPinnedTLSLineConnection {
        let connection = StreamingFakeConnection()
        lock.lock()
        created.append(connection)
        lock.unlock()
        return connection
    }

    func connections() -> [StreamingFakeConnection] {
        lock.lock()
        defer { lock.unlock() }
        return created
    }
}

/// A line connection the test drives directly. It reproduces the transport's framing contract rather
/// than any client behavior: every read reports bytes, and only non-empty lines are delivered as lines
/// (both pinned-TLS backends drop empty lines before `onLine`).
private final class StreamingFakeConnection: SpacesPinnedTLSLineConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var onLine: (@Sendable (Data) -> Void)?
    private var onBytesReceived: (@Sendable () -> Void)?
    private var cancelled = false

    func sendLine(_ line: Data, timeout: TimeInterval) throws {}

    func readLine(timeout: TimeInterval) throws -> Data { throw SpacesPinnedTLSConnectionError.timeout }

    func startReceiveLoop(
        onLine: @escaping @Sendable (Data) -> Void, onBytesReceived: @escaping @Sendable () -> Void,
        onClosed: @escaping @Sendable ((any Error)?) -> Void
    ) {
        lock.lock()
        self.onLine = onLine
        self.onBytesReceived = onBytesReceived
        lock.unlock()
    }

    func deliverPayload(_ payload: GhosttyRemoteSessionStatePayload) {
        guard let line = try? GhosttyRemoteSessionStateCodec.encodeLine(payload) else { return }
        lock.lock()
        let handlers = (onLine, onBytesReceived)
        lock.unlock()
        handlers.1?()
        handlers.0?(line.dropLast())
    }

    func deliverKeepalive() {
        lock.lock()
        let notifyBytes = onBytesReceived
        lock.unlock()
        notifyBytes?()
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
