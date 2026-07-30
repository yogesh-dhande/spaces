#if os(Linux)
    import Foundation
    import Testing
    import spacesterminalcore

    @testable import spacesterminalghostty

    /// Regression gate for the fork-child runtime deadlock (#371): a PTY child forked from this
    /// heavily multithreaded process must always reach exec and produce output, never park forever
    /// on a lock it inherited from the parent. Before the fix a debugger caught the child dead in
    /// `pthread_mutex_lock` under `swift_getTypeByMangledName` — the Swift runtime's conformance
    /// cache, locked by another thread at the fork instant — at roughly 1 in 100-200 spawns on a
    /// busy 4-core box. One organic spawn per behavior suite made that a slow, rotating flake;
    /// this suite makes it a deterministic gate by attacking the race directly: many spawns in a
    /// row while churn tasks keep the runtime's metadata and allocator locks hot. At the measured
    /// pre-fix rate, 200 amplified spawns fail far more often than not, while the fixed spawn path
    /// (the child's entire pre-exec body in C, `spaces_pty_child_exec`) cannot deadlock this way
    /// at all.
    ///
    /// A failure here means a child stayed silent past its deadline: the hang diagnostics print
    /// the child's /proc state and blocked pc before the assertion fires.
    ///
    /// Swift Testing (not XCTest) and a nonisolated body for the same reasons as the sibling
    /// suites (async XCTest deadlocks on Linux; the core is `TerminalEngineActor`-isolated).
    /// `.serialized` because the suite mutates the process-wide SPACES_* environment and owns
    /// real PTY children.
    @Suite(.serialized) final class GhosttyLinuxHeadlessSpawnStressTests {
        private let originalDatabasePath: String?
        private let originalRuntimeDirectory: String?
        private let databaseRoot: URL

        /// Carries an engine-isolated reference back out to the nonisolated test body; it is only
        /// ever used again through an engine bridge.
        private final class Box<Value>: @unchecked Sendable {
            let value: Value
            init(_ value: Value) { self.value = value }
        }

        init() throws {
            originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
            originalRuntimeDirectory = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            databaseRoot = root
            setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
            setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("runtime", isDirectory: true).path, 1)
        }

        deinit {
            if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
            if let originalRuntimeDirectory { setenv("SPACES_RUNTIME_DIR", originalRuntimeDirectory, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
            try? FileManager.default.removeItem(at: databaseRoot)
        }

        /// 400 spawns detected the pre-fix deadlock in ~9 of 10 runs on a 4-vCPU runner-shaped VM
        /// (measured per-spawn hit rate ~0.55% under the conformance churn below); the fixed spawn
        /// path completes the whole suite in ~15s.
        private static let spawnCount = 400
        private static let marker = "SPAWN_STRESS_OK"
        /// Generous next to the sub-second healthy spawn, tiny next to the sibling suites' 30s waits:
        /// a deadlocked child never produces the marker, so a long deadline only slows the failure.
        private static let perSpawnTimeout: TimeInterval = 10

        /// Work that leans on exactly the lock the deadlock was caught holding — the WRITE side of
        /// the runtime's conformance cache (`ConformanceState::cacheResult`). A loop over fixed
        /// types goes quiet after one iteration: everything it touches is cached, and cache reads
        /// are lock-free, so only first-time instantiations contend. Every forked child is a
        /// first-timer (its cache inserts die with it), which is why every organic spawn is
        /// exposed; to be a deterministic gate the churn must therefore keep MINTING new generic
        /// instantiations, which `_typeByName` on ever-deeper composed type names does — each
        /// unique composition is a fresh metadata build plus conformance-cache insert.
        private struct ChurnPayload: Codable {
            var index: Int
            var label: String
            var values: [Double]
        }

        /// Lock-guarded stop signal the churn threads poll; `@unchecked Sendable` so the thread
        /// closures may capture it under Swift 6 checking.
        private final class ChurnStop: @unchecked Sendable {
            private let lock = NSLock()
            private var stopped = false

            func stop() {
                lock.lock()
                stopped = true
                lock.unlock()
            }

            var isStopped: Bool {
                lock.lock()
                defer { lock.unlock() }
                return stopped
            }
        }

        private static func runChurn(until stop: ChurnStop, seed: Int) {
            let encoder = JSONEncoder()
            let decoder = JSONDecoder()
            // MANGLED element manglings per churn thread, so the threads insert distinct
            // instantiations instead of racing to cache the same ones once. `_typeByName`
            // returns nil for dotted generic syntax ("Swift.Array<Swift.Int>") without building
            // anything — only proper manglings reach the metadata machinery.
            let elements = ["Si", "Sd", "SS", "Sb", "Su", "Sf"]
            var iteration = 0
            while !stop.isStopped {
                iteration += 1
                // The iteration counter, written in base 2 as a nesting of Array ("Say…G") and
                // Optional ("…Sg") wrappers, mangles a composition the runtime has never built in
                // this process: every lookup is a fresh metadata build plus a conformance-cache
                // INSERT — the lock-taking write path the deadlock lives on. Depth stays
                // logarithmic in the counter.
                var name = elements[seed % elements.count]
                var n = iteration
                while n > 0 {
                    name = n % 2 == 0 ? "Say\(name)G" : "\(name)Sg"
                    n /= 2
                }
                // The deadlock's lock is the CONFORMANCE cache, not the metadata cache: the child
                // died in cacheResult under conformsToProtocol. A bare metadata build of Array
                // nestings never checks a conformance (Array's parameter is unconstrained), so the
                // casts below are the part that actually contends the deadlocked lock — each one
                // resolves and INSERTS the fresh type's (conditional) conformances.
                if let minted = _typeByName(name) {
                    _ = minted as? any Decodable.Type
                    _ = minted as? any Equatable.Type
                }
                let payload = ChurnPayload(index: iteration, label: "churn-\(seed)-\(iteration)", values: [Double(iteration)])
                if let data = try? encoder.encode(payload), let decoded = try? decoder.decode(ChurnPayload.self, from: data) {
                    _ = String(describing: decoded)
                }
            }
        }

        @Test func everySpawnedChildReachesItsShellUnderRuntimeChurn() async throws {
            let churnStop = ChurnStop()
            let churnThreads = (0..<3).map { seed in
                Thread {
                    Self.runChurn(until: churnStop, seed: seed)
                }
            }
            for thread in churnThreads { thread.start() }
            defer { churnStop.stop() }

            for spawn in 0..<Self.spawnCount {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let paths = TerminalSessionPaths(rootDirectory: root.path)
                try paths.ensureDirectories()

                let coreBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionCore> in
                    let core = GhosttyEmbeddedSessionCore(
                        launchConfiguration: TerminalSessionLaunchConfiguration(
                            sessionID: "spawn-stress-\(spawn)-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "owner",
                            workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh",
                            command: "printf \(Self.marker)", createdAt: "2026-07-29T00:00:00Z", workspaceID: "workspace-1", kind: .shell),
                        paths: paths)
                    try core.startIfNeeded()
                    return Box(core)
                }
                let core = coreBox.value
                defer { TerminalEngineActor.runSynchronously { core.terminate() } }

                let outputPath = paths.outputPath
                let started = Date()
                let deadline = started.addingTimeInterval(Self.perSpawnTimeout)
                var sawMarker = false
                while Date() < deadline {
                    if ((try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? "").contains(Self.marker) {
                        sawMarker = true
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                if !sawMarker {
                    await GhosttyLinuxHeadlessHangDiagnostics.report(
                        wait: "spawn stress child #\(spawn) must print its marker", elapsed: Date().timeIntervalSince(started),
                        timeout: Self.perSpawnTimeout, transcriptPath: outputPath)
                }
                #expect(sawMarker, "spawned child #\(spawn) produced no output within \(Self.perSpawnTimeout)s")
                if !sawMarker { break }
            }
        }
    }
#endif
