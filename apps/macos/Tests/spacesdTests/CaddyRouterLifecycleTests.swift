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
            try Data(
                """
                #!/bin/sh
                if [ "$1" = "run" ]; then
                  echo run >> "$SPACES_TEST_CADDY_EVENTS"
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
                "SPACES_TEST_CADDY_RELEASE_RUN", "SPACES_TEST_CADDY_SOCKET",
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
                try? FileManager.default.removeItem(at: socket)
                for (name, value) in originalEnvironment { if let value { setenv(name, value, 1) } else { unsetenv(name) } }
                SpacesProfile.resetCacheForTesting()
            }
            setenv("SPACES_TEST_CADDY_EVENTS", events.path, 1)
            setenv("SPACES_TEST_CADDY_RUN_STARTED", runStarted.path, 1)
            setenv("SPACES_TEST_CADDY_RELEASE_RUN", releaseRun.path, 1)
            setenv("SPACES_TEST_CADDY_SOCKET", socket.path, 1)
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
            XCTAssertTrue(waitForFile(at: runStarted.path, timeout: 2))

            let stopFinished = LockedFlag()
            let stopThread = Thread {
                lifecycle.stop()
                stopFinished.set()
            }
            stopThread.start()
            Thread.sleep(forTimeInterval: 0.1)
            XCTAssertFalse(stopFinished.value)

            try Data().write(to: releaseRun)
            XCTAssertTrue(waitUntil(timeout: 4) { stopFinished.value })
            XCTAssertTrue(waitForThreadToFinish(ensureThread, timeout: 1))
            XCTAssertTrue(waitForThreadToFinish(stopThread, timeout: 1))
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
