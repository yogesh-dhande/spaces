import Foundation
import Testing
import spacesterminalcore

@testable import spacesdevicecore

/// Covers the resources stream's liveness watch: a transport that stays open while delivering no frames
/// is reported as a stall so the Resources pane's subscription coordinator reconnects, and a steady frame
/// cadence is never reported that way.
@Suite struct SpacesDeviceResourcesStreamClientTests {
    private static let fingerprint = "SHA256:" + String(repeating: "e", count: 64)
    private static let port = 47_848
    private static let silenceTimeout: TimeInterval = 0.8
    private static let stallReportCeiling: TimeInterval = 30

    @Test func silenceAfterAFrameReportsAStallAndReleasesTheConnection() async throws {
        let connection = ResourcesFakeConnection()
        let events = ResourcesStreamRecorder()
        let client = try Self.makeClient(connection: connection, events: events)
        try client.start(timeoutSeconds: 1)

        connection.deliverFrame(Self.frame())
        #expect(await events.waitUntil(timeout: 2) { events.frameCount() >= 1 })

        #expect(await events.waitUntil(timeout: Self.stallReportCeiling) { events.disconnectCount() > 0 })
        guard case SpacesDeviceAPIRequestClientError.streamStalled = try #require(events.disconnectError()) else {
            Issue.record("Expected streamStalled, got \(String(describing: events.disconnectError()))")
            return
        }
        #expect(connection.isCancelled())
    }

    @Test func steadyFramesKeepTheStreamConnected() async throws {
        let connection = ResourcesFakeConnection()
        let events = ResourcesStreamRecorder()
        let client = try Self.makeClient(connection: connection, events: events)
        try client.start(timeoutSeconds: 1)
        defer { client.stop() }

        // Frames come from a dedicated thread, like the watchdog that judges them: under a loaded test host
        // a `Task.sleep` cadence on the saturated cooperative pool oversleeps by seconds and reads as a stall.
        let result = ResourcesSteadyObservationResult()
        SpacesBlockingIOThread.spawn(name: "spaces.test.resources-stream-steady") {
            let deadline = Date().addingTimeInterval(Self.silenceTimeout * 3)
            while Date() < deadline {
                connection.deliverFrame(Self.frame())
                Thread.sleep(forTimeInterval: Self.silenceTimeout / 4)
            }
            result.capture(disconnectCount: events.disconnectCount(), cancelled: connection.isCancelled())
        }

        #expect(await result.waitForCompletion(timeout: Self.stallReportCeiling))
        let captured = try #require(result.captured())
        #expect(captured.disconnectCount == 0)
        #expect(!captured.cancelled)
    }

    private static func makeClient(
        connection: ResourcesFakeConnection, events: ResourcesStreamRecorder
    ) throws -> SpacesDeviceResourcesStreamClient
    {
        let resolver = SpacesDeviceEndpointResolver(
            hosts: ["lan"], port: port, certificateFingerprint: fingerprint, activeHost: nil, onProvenHost: { _ in },
            connect: { _, _, _, _ in connection })
        return try SpacesDeviceResourcesStreamClient(
            authToken: nil, clientApp: nil, resolver: resolver, silenceTimeout: Self.silenceTimeout,
            onFrame: { _ in events.recordFrame() }, onDisconnect: { events.recordDisconnect($0) })
    }

    private static func frame() -> SpacesDeviceResourcesFrame {
        SpacesDeviceResourcesFrame(
            sampledAt: Date(), processorCount: 8, physicalMemoryBytes: 1 << 33,
            daemon: SpacesDeviceResourceUsage(cpuPercent: 1, memoryBytes: 1 << 20), terminals: [])
    }
}

private final class ResourcesSteadyObservationResult: @unchecked Sendable {
    struct Captured {
        let disconnectCount: Int
        let cancelled: Bool
    }

    private let lock = NSLock()
    private var value: Captured?

    func capture(disconnectCount: Int, cancelled: Bool) {
        lock.lock()
        value = Captured(disconnectCount: disconnectCount, cancelled: cancelled)
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

private final class ResourcesStreamRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var disconnects: [(any Error)?] = []

    func recordFrame() {
        lock.lock()
        frames += 1
        lock.unlock()
    }

    func recordDisconnect(_ error: (any Error)?) {
        lock.lock()
        disconnects.append(error)
        lock.unlock()
    }

    func frameCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return frames
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

    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

/// A line connection the test drives directly: every delivered frame reports bytes, then its line.
private final class ResourcesFakeConnection: SpacesPinnedTLSLineConnection, @unchecked Sendable {
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

    func deliverFrame(_ frame: SpacesDeviceResourcesFrame) {
        guard let line = try? SpacesDeviceResourcesStreamCodec.encodeLine(frame) else { return }
        lock.lock()
        let handlers = (onLine, onBytesReceived)
        lock.unlock()
        handlers.1?()
        handlers.0?(line.dropLast())
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
