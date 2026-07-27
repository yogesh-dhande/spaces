import Foundation
import XCTest

#if os(macOS)
    @testable import spacesd
    @testable import spacesterminalcore

    final class CaddyRouterLifecycleTests: XCTestCase {
        func testStopWaitsForInFlightEnsureRunningThenPreventsRestart() throws {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
                "caddy-router-lifecycle-\(UUID().uuidString)", isDirectory: true)
            let runtimeDirectory = directory.appendingPathComponent("runtime", isDirectory: true)
            try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let fakeCaddy = directory.appendingPathComponent("caddy", isDirectory: false)
            let events = directory.appendingPathComponent("events", isDirectory: false)
            let runStarted = directory.appendingPathComponent("run-started", isDirectory: false)
            let releaseRun = directory.appendingPathComponent("release-run", isDirectory: false)
            let pids = directory.appendingPathComponent("pids", isDirectory: false)
            try Data(
                """
                #!/bin/sh
                if [ "$1" = "run" ]; then
                  echo run >> "$SPACES_TEST_CADDY_EVENTS"
                  echo $$ >> "$SPACES_TEST_CADDY_PIDS"
                  touch "$SPACES_TEST_CADDY_RUN_STARTED"
                  while [ ! -f "$SPACES_TEST_CADDY_RELEASE_RUN" ]; do
                    sleep 0.02
                  done
                  touch "$SPACES_TEST_CADDY_SOCKET"
                  while [ -f "$SPACES_TEST_CADDY_SOCKET" ]; do
                    sleep 0.02
                  done
                  exit 0
                fi
                if [ "$1" = "stop" ]; then
                  echo stop >> "$SPACES_TEST_CADDY_EVENTS"
                  rm -f "$SPACES_TEST_CADDY_SOCKET"
                  exit 0
                fi
                exit 1
                """.utf8
            ).write(to: fakeCaddy)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCaddy.path)

            let environmentKeys = [
                SpacesProfile.databasePathEnvironmentVariable, SpacesProfile.runtimeDirectoryEnvironmentVariable,
                CaddyService.executableEnvironmentVariable, "SPACES_TEST_CADDY_EVENTS", "SPACES_TEST_CADDY_RUN_STARTED",
                "SPACES_TEST_CADDY_RELEASE_RUN", "SPACES_TEST_CADDY_SOCKET", "SPACES_TEST_CADDY_PIDS",
            ]
            let originalEnvironment = environmentKeys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
            setenv(SpacesProfile.databasePathEnvironmentVariable, directory.appendingPathComponent("spaces.db").path, 1)
            setenv(SpacesProfile.runtimeDirectoryEnvironmentVariable, runtimeDirectory.path, 1)
            setenv(CaddyService.executableEnvironmentVariable, fakeCaddy.path, 1)
            SpacesProfile.resetCacheForTesting()
            // The admin socket lives under a short fixed root keyed by a hash of the runtime
            // directory, not the runtime directory itself; resolve it the same way the code under
            // test does instead of assuming the old runtime-directory-relative location.
            let socket = URL(fileURLWithPath: try CaddyService.adminSocketPath())
            defer {
                try? Data().write(to: releaseRun)
                // If an assertion failed before releaseRun unblocked the script normally, the
                // fake caddy's `run` branch may still be looping on the socket file. Kill any
                // recorded PIDs directly so the run-loop can't outlive the test process and
                // touch the socket again after we remove it below.
                let recordedPIDs = (try? String(contentsOf: pids)) ?? ""
                for line in recordedPIDs.split(separator: "\n") {
                    if let pid = Int32(line.trimmingCharacters(in: .whitespaces)) { kill(pid_t(pid), SIGKILL) }
                }
                try? FileManager.default.removeItem(at: socket)
                for (name, value) in originalEnvironment { if let value { setenv(name, value, 1) } else { unsetenv(name) } }
                SpacesProfile.resetCacheForTesting()
            }
            setenv("SPACES_TEST_CADDY_EVENTS", events.path, 1)
            setenv("SPACES_TEST_CADDY_RUN_STARTED", runStarted.path, 1)
            setenv("SPACES_TEST_CADDY_RELEASE_RUN", releaseRun.path, 1)
            setenv("SPACES_TEST_CADDY_SOCKET", socket.path, 1)
            setenv("SPACES_TEST_CADDY_PIDS", pids.path, 1)
            SpacesProfile.resetCacheForTesting()

            let lifecycle = CaddyRouterLifecycle()
            let ensureResult = LockedResult()
            let ensureThread = Thread {
                do {
                    try lifecycle.ensureRunning(configJSON: Data("{}".utf8))
                    ensureResult.set(.success(()))
                } catch { ensureResult.set(.failure(error)) }
            }
            ensureThread.start()
            XCTAssertTrue(waitForFile(at: runStarted.path, timeout: 30))

            let stopEntered = LockedFlag()
            let stopFinished = LockedFlag()
            let stopThread = Thread {
                // `stop(debugOnEnter:)` fires the instant this call is made, before it can even attempt to
                // acquire the internal lock -- see its doc comment for why a flag set by the caller right
                // before the call cannot serve the same purpose (a preemption there can let this test
                // release the fake Caddy's `run` loop while `stop()` has not been entered at all, so a
                // `stop()` that does not wait for an in-flight call could still pass).
                lifecycle.stop(debugOnEnter: { stopEntered.set() })
                stopFinished.set()
            }
            stopThread.start()
            // Wait for the stop thread to have entered `stop()` — a signal the call itself emits — instead of
            // sleeping for a guessed interval and hoping it got that far. `ensureRunning` is still blocked
            // inside `CaddyService.ensureRunning`'s poll loop, holding `lifecycle`'s lock, until `releaseRun`
            // is written below: the fake caddy's `run` branch only touches the admin socket file (the signal
            // that poll loop waits on) once `releaseRun` exists, and we have not written it yet. So the
            // assertion right after this wait proves, by construction rather than by scheduling luck, that a
            // `stop()` which serializes on that same lock cannot have returned: it establishes exactly "stop()
            // must not return until the ensureRunning it interrupted has released the lock", i.e. has
            // returned.
            //
            // Accepted detection limit: against a regressed `stop()` that skips the lock, these two asserts
            // alone can still pass — `stopEntered` fires before the lock attempt, and a lock-free `stop()`
            // spends milliseconds in its caddy-stop child, so `stopFinished` can legitimately still read
            // false here. What catches that regression is the tail of the test: a `stop()` that ran early
            // removed no socket (none existed yet) and never released the fake's `run` loop, so the final
            // no-socket assert fails whenever stop's cleanup landed before the fake touched the socket.
            // That makes detection scheduling-dependent (an intermittent failure, not a certain one);
            // proving "stop is blocked on the lock" deterministically would require instrumenting the
            // production lock itself, and any such seam is deleted by the same regression it would guard
            // against.
            XCTAssertTrue(waitUntil(timeout: 30) { stopEntered.value })
            XCTAssertFalse(stopFinished.value)

            try Data().write(to: releaseRun)
            XCTAssertTrue(waitUntil(timeout: 30) { stopFinished.value })
            XCTAssertTrue(waitForThreadToFinish(ensureThread, timeout: 10))
            XCTAssertTrue(waitForThreadToFinish(stopThread, timeout: 10))
            try XCTUnwrap(ensureResult.value).get()
            XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))

            let eventsBeforeStoppedEnsure = readEvents(at: events)
            try lifecycle.ensureRunning(configJSON: Data("{}".utf8))
            XCTAssertEqual(readEvents(at: events), eventsBeforeStoppedEnsure)
            XCTAssertEqual(eventsBeforeStoppedEnsure.filter { $0 == "run" }.count, 1)
            XCTAssertEqual(eventsBeforeStoppedEnsure.filter { $0 == "stop" }.count, 1)
        }

        private func waitForFile(at path: String, timeout: TimeInterval) -> Bool {
            waitUntil(timeout: timeout) { FileManager.default.fileExists(atPath: path) }
        }

        private func waitForThreadToFinish(_ thread: Thread, timeout: TimeInterval) -> Bool { waitUntil(timeout: timeout) { thread.isFinished } }

        private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                Thread.sleep(forTimeInterval: 0.02)
            }
            return condition()
        }

        private func readEvents(at url: URL) -> [String] { ((try? String(contentsOf: url)) ?? "").split(separator: "\n").map(String.init) }
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue = false

        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }

        func set() {
            lock.lock()
            storedValue = true
            lock.unlock()
        }
    }

    private final class LockedResult: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue: Result<Void, any Error>?

        var value: Result<Void, any Error>? {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }

        func set(_ value: Result<Void, any Error>) {
            lock.lock()
            storedValue = value
            lock.unlock()
        }
    }
#endif
