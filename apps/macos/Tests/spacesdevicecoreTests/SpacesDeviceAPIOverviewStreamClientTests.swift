import Dispatch
import Foundation
import Testing
import spacesterminalcore

@testable import spacesdevicecore

/// Covers the device-overview stream's liveness watch, mirroring
/// `SpacesDeviceAPIStateStreamClientTests`: a transport that stays open while carrying nothing is
/// reported as a stall so the owner (the sidebar's `RemoteOverviewSubscriptionCoordinator`) can mark the
/// device offline and retry, and the daemon's keepalive frames are what keep an idle overview subscription
/// (calmed to `SpacesDeviceAPIServer.overviewMetadataCoalesceInterval` under ordinary operation) from being
/// reported that way.
@Suite struct SpacesDeviceAPIOverviewStreamClientTests {
    private static let fingerprint = "SHA256:" + String(repeating: "d", count: 64)
    private static let port = 47_847
    private static let silenceTimeout: TimeInterval = 0.8
    private static let stallReportCeiling: TimeInterval = 30

    @Test func silenceAfterAPayloadReportsAStallAndReleasesTheConnection() async throws {
        let dialer = OverviewConnectionDialer()
        let events = OverviewStreamRecorder()
        let client = try SpacesDeviceAPIOverviewStreamClient(
            authToken: nil, clientApp: nil, resolver: Self.makeResolver(dialer: dialer), silenceTimeout: Self.silenceTimeout,
            onOverview: { events.recordOverview($0) }, onDisconnect: { events.recordDisconnect($0) })
        try client.start(timeoutSeconds: 1)

        let connection = try #require(dialer.connections().first)
        connection.deliverPayload(Self.payload())
        #expect(await events.waitForOverviews(count: 1, timeout: 2))

        #expect(await events.waitForDisconnect(timeout: Self.stallReportCeiling))
        guard case SpacesDeviceAPIRequestClientError.streamStalled = try #require(events.disconnectError()) else {
            Issue.record("Expected streamStalled, got \(String(describing: events.disconnectError()))")
            return
        }
        #expect(connection.isCancelled())
    }

    @Test func keepaliveFramesKeepAnIdleStreamConnected() async throws {
        let dialer = OverviewConnectionDialer()
        let events = OverviewStreamRecorder()
        let client = try SpacesDeviceAPIOverviewStreamClient(
            authToken: nil, clientApp: nil, resolver: Self.makeResolver(dialer: dialer), silenceTimeout: Self.silenceTimeout,
            onOverview: { events.recordOverview($0) }, onDisconnect: { events.recordDisconnect($0) })
        try client.start(timeoutSeconds: 1)
        defer { client.stop() }

        let connection = try #require(dialer.connections().first)
        let keepaliveInterval = Self.silenceTimeout / 4
        let result = OverviewKeepaliveObservationResult()
        SpacesBlockingIOThread.spawn(name: "spaces.test.overview-stream-keepalive") {
            let deadline = Date().addingTimeInterval(Self.silenceTimeout * 3)
            while Date() < deadline {
                connection.deliverKeepalive()
                Thread.sleep(forTimeInterval: keepaliveInterval)
            }
            result.capture(disconnectCount: events.disconnectCount(), overviewCount: events.overviewCount(), cancelled: connection.isCancelled())
        }

        #expect(await result.waitForCompletion(timeout: Self.stallReportCeiling))
        let captured = try #require(result.captured())
        #expect(captured.disconnectCount == 0)
        #expect(captured.overviewCount == 0)
        #expect(!captured.cancelled)
    }

    private static func payload() -> SpacesDeviceOverviewPayload {
        SpacesDeviceOverviewPayload(
            workspaces: [], sessions: [],
            daemonStatus: TerminalServiceDaemonStatus(version: "test", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0))
    }

    private static func makeResolver(dialer: OverviewConnectionDialer) -> SpacesDeviceEndpointResolver {
        SpacesDeviceEndpointResolver(
            hosts: ["lan"], port: port, certificateFingerprint: fingerprint, activeHost: nil, onProvenHost: { _ in },
            connect: { _, _, _, _ in dialer.connect() })
    }
}

private final class OverviewStreamRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var overviews: [SpacesDeviceOverviewPayload] = []
    private var disconnects: [(any Error)?] = []

    func recordOverview(_ payload: SpacesDeviceOverviewPayload) {
        lock.lock()
        overviews.append(payload)
        lock.unlock()
    }

    func recordDisconnect(_ error: (any Error)?) {
        lock.lock()
        disconnects.append(error)
        lock.unlock()
    }

    func overviewCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return overviews.count
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

    func waitForOverviews(count: Int, timeout: TimeInterval) async -> Bool { await waitUntil(timeout: timeout) { self.overviewCount() >= count } }

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

private final class OverviewKeepaliveObservationResult: @unchecked Sendable {
    struct Captured {
        let disconnectCount: Int
        let overviewCount: Int
        let cancelled: Bool
    }

    private let lock = NSLock()
    private var value: Captured?

    func capture(disconnectCount: Int, overviewCount: Int, cancelled: Bool) {
        lock.lock()
        value = Captured(disconnectCount: disconnectCount, overviewCount: overviewCount, cancelled: cancelled)
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

private final class OverviewConnectionDialer: @unchecked Sendable {
    private let lock = NSLock()
    private var created: [OverviewStreamingFakeConnection] = []

    func connect() -> any SpacesPinnedTLSLineConnection {
        let connection = OverviewStreamingFakeConnection()
        lock.lock()
        created.append(connection)
        lock.unlock()
        return connection
    }

    func connections() -> [OverviewStreamingFakeConnection] {
        lock.lock()
        defer { lock.unlock() }
        return created
    }
}

/// A line connection the test drives directly, reproducing the transport's framing contract (every read
/// reports bytes; only non-empty lines reach `onLine`, matching both pinned-TLS backends dropping empty
/// keepalive lines before decoding).
private final class OverviewStreamingFakeConnection: SpacesPinnedTLSLineConnection, @unchecked Sendable {
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

    func deliverPayload(_ payload: SpacesDeviceOverviewPayload) {
        guard let line = try? SpacesDeviceOverviewStreamCodec.encodeLine(payload) else { return }
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
