import Foundation
import Testing

@testable import spacesterminalcore

/// `Thread.current` is unavailable directly inside an `async` function body (it is marked
/// `NS_SWIFT_UNAVAILABLE_FROM_ASYNC`), so every test below reads it through this ordinary synchronous
/// helper instead.
private func currentThreadSnapshot() -> (name: String?, isMainThread: Bool, identifier: ObjectIdentifier) {
    let thread = Thread.current
    return (thread.name, thread.isMainThread, ObjectIdentifier(thread))
}

/// Records one snapshot from whichever thread calls in, guarded by a lock rather than a bare captured
/// var, since the recording happens from a thread other than the caller's.
private final class ThreadSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: (name: String?, isMainThread: Bool, identifier: ObjectIdentifier)?

    func record(_ value: (name: String?, isMainThread: Bool, identifier: ObjectIdentifier)) {
        lock.lock()
        snapshot = value
        lock.unlock()
    }

    func value() -> (name: String?, isMainThread: Bool, identifier: ObjectIdentifier)? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
}

/// Covers the contract `SpacesDeviceEndpointResolver` and `TerminalLinkOpenCoordinator` depend on for
/// their blocking transport I/O (issue #611): `run` hands back the body's value or rethrows its error,
/// and both `run` and `spawn` execute their body on a real dedicated thread rather than the calling
/// thread or a Swift cooperative-pool thread.
///
/// Swift Testing, not XCTest: this suite runs on the Linux daemon-side lane too, where corelibs-xctest's
/// blocked main thread never drains queued async work, so an async XCTest deadlocks before its first
/// line ever runs (see run_linux_tests.sh).
@Suite struct SpacesBlockingIOThreadTests {
    @Test func runReturnsTheBodysValue() async throws {
        let value = try await SpacesBlockingIOThread.run(name: "test.run.value") { 42 }
        #expect(value == 42)
    }

    @Test func runRethrowsTheBodysError() async {
        struct TestFailure: Error, Equatable {}
        await #expect(throws: TestFailure.self) {
            _ = try await SpacesBlockingIOThread.run(name: "test.run.error") { throw TestFailure() }
        }
    }

    @Test func runExecutesTheBodyOnADedicatedThreadNamedAsRequested() async throws {
        let callingThread = currentThreadSnapshot()
        let observed = try await SpacesBlockingIOThread.run(name: "spaces.test.dedicated-thread") { currentThreadSnapshot() }
        // Linux's pthread API caps names at 15 bytes, so corelibs-foundation's name plumbing silently
        // fails for a name this long and `Thread.current.name` reads back the truncated process name
        // instead. The name is a diagnostic only, so that's checked on Darwin alone; every platform still
        // has to prove the body ran on its own dedicated thread, not the caller's or the main thread.
        #if canImport(ObjectiveC)
            #expect(observed.name == "spaces.test.dedicated-thread")
        #endif
        #expect(!observed.isMainThread)
        #expect(observed.identifier != callingThread.identifier)
    }

    /// `spawn` is the fire-and-forget entry point `SpacesDeviceEndpointResolver` uses for its race
    /// attempts: it must actually run the body, off the calling thread, without anyone awaiting it.
    /// A synchronous test waiting on a `DispatchSemaphore` (rather than an `async` poll) proves this
    /// without depending on `spawn`'s caller ever being `async` itself.
    @Test func spawnRunsTheBodyOnADedicatedThread() {
        let bodyRan = DispatchSemaphore(value: 0)
        let callingThread = currentThreadSnapshot()
        let observedBox = ThreadSnapshotBox()
        SpacesBlockingIOThread.spawn(name: "spaces.test.spawn") {
            observedBox.record(currentThreadSnapshot())
            bodyRan.signal()
        }
        #expect(bodyRan.wait(timeout: .now() + 5) == .success)
        let observed = observedBox.value()
        // See the name-length note above: Linux's 15-byte pthread name cap makes exact-name assertions
        // Darwin-only, while dedicated-thread execution is checked on every platform.
        #if canImport(ObjectiveC)
            #expect(observed?.name == "spaces.test.spawn")
        #endif
        #expect(observed?.identifier != callingThread.identifier)
    }
}
