import XCTest
import spacessessionindex
import spacesterminalcore

@testable import spacesd

#if os(macOS)
    final class AgentSessionIndexServiceTests: XCTestCase {
        private var root: URL!
        private var locations: AgentSessionStoreLocations!

        override func setUpWithError() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "agent-session-index-service-\(UUID().uuidString)", isDirectory: true)
            locations = AgentSessionStoreLocations(home: root.appendingPathComponent("home", isDirectory: true))
            let root = self.root!
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        }

        private final class LockedCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0

            func increment() -> Int {
                lock.lock()
                defer { lock.unlock() }
                value += 1
                return value
            }
        }

        private var indexURL: URL { root.appendingPathComponent("agent-session-index.sqlite") }

        private func makeService(
            refreshInterval: TimeInterval = 3600, minimumSearchRefreshSpacing: TimeInterval = 0,
            isSuspended: @escaping @Sendable () -> Bool = { false }
        ) -> AgentSessionIndexService {
            AgentSessionIndexService(
                indexURL: indexURL, locations: locations, refreshInterval: refreshInterval, minimumSearchRefreshSpacing: minimumSearchRefreshSpacing,
                isSuspended: isSuspended, onError: { XCTFail("Unexpected index error: \($0)") })
        }

        private func writeClaudeSession(_ key: String, text: String) throws {
            let directory = locations.claudeCodeProjects.appendingPathComponent("-work-app", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let user =
                #"{"type":"user","message":{"role":"user","content":"\#(text)"},"timestamp":"2026-01-10T10:00:00.000Z","entrypoint":"cli","cwd":"/work/app"}"#
            let reply =
                #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]},"timestamp":"2026-01-10T10:00:01.000Z","entrypoint":"cli","cwd":"/work/app"}"#
            try Data((user + "\n" + reply + "\n").utf8).write(to: directory.appendingPathComponent("\(key).jsonl"))
        }

        private func keys(_ service: AgentSessionIndexService, query: String = "") throws -> [String] {
            try service.search(query: query, page: 0, agents: [], folders: nil).page.results.map(\.sessionKey)
        }

        /// Polls until `condition` holds; the index builds on its own thread, so a test can only wait for it.
        private func waitUntil(_ description: String, _ condition: () throws -> Bool) throws {
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if try condition() { return }
                Thread.sleep(forTimeInterval: 0.02)
            }
            XCTFail("Timed out waiting for \(description).")
        }

        func testTheFirstBuildMakesSessionsSearchableAndClearsTheBuildingFlag() throws {
            try writeClaudeSession("first", text: "heron migration")
            let service = makeService()
            defer { service.stop() }

            XCTAssertTrue(
                try service.search(query: "heron", page: 0, agents: [], folders: nil).isBuilding, "Before the first pass, results are partial.")
            service.start()

            try waitUntil("the first build") { try !service.search(query: "heron", page: 0, agents: [], folders: nil).isBuilding }
            let snapshot = try service.search(query: "heron", page: 0, agents: [], folders: nil)
            XCTAssertEqual(snapshot.page.results.map(\.sessionKey), ["first"])
            XCTAssertEqual(snapshot.availableAgents, [.claudeCode])
        }

        func testASearchAsksForARefreshWithoutWaitingForIt() throws {
            let service = makeService()
            defer { service.stop() }
            service.start()
            try waitUntil("the first build") { try !service.search(query: "", page: 0, agents: [], folders: nil).isBuilding }
            XCTAssertEqual(try keys(service), [])

            try writeClaudeSession("later", text: "written after the first build")

            // The periodic pass is an hour away, so only the search's own request can find the new session.
            try waitUntil("a search-requested refresh to find the new session") { try keys(service) == ["later"] }
        }

        func testASearchReportsItsScheduledRefreshAsRefreshingUntilItsResultsAreVisible() throws {
            // The spacing lets the polling below ask for one pass, not a new one after each answer.
            let service = makeService(minimumSearchRefreshSpacing: 1)
            defer { service.stop() }
            service.start()
            try waitUntil("the first build") { try !service.search(query: "", page: 0, agents: [], folders: nil).isBuilding }
            Thread.sleep(forTimeInterval: 1.1)
            try writeClaudeSession("later", text: "written after the first build")

            // The answer may come back before the requested pass has started; clients stop polling at the first
            // answer that says nothing is refreshing, so that answer must already hold the pass's results.
            let deadline = Date().addingTimeInterval(30)
            var snapshot = try service.search(query: "", page: 0, agents: [], folders: nil)
            while snapshot.progress.isRefreshing, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
                snapshot = try service.search(query: "", page: 0, agents: [], folders: nil)
            }
            XCTAssertEqual(snapshot.page.results.map(\.sessionKey), ["later"])
        }

        func testSearchesDoNotRequestRefreshesCloserTogetherThanTheMinimumSpacing() throws {
            let service = makeService(minimumSearchRefreshSpacing: 3600)
            defer { service.stop() }
            service.start()
            try waitUntil("the first build") { try !service.search(query: "", page: 0, agents: [], folders: nil).isBuilding }

            try writeClaudeSession("later", text: "written after the first build")
            for _ in 0..<20 { _ = try keys(service) }
            Thread.sleep(forTimeInterval: 0.3)

            XCTAssertEqual(try keys(service), [], "The first pass just ran, so a search is too soon to ask for another.")
        }

        func testASuspendedDaemonRunsNoPass() throws {
            try writeClaudeSession("first", text: "heron migration")
            let service = makeService(isSuspended: { true })
            defer { service.stop() }

            service.start()
            Thread.sleep(forTimeInterval: 0.3)

            let snapshot = try service.search(query: "", page: 0, agents: [], folders: nil)
            XCTAssertTrue(snapshot.page.results.isEmpty)
            XCTAssertTrue(snapshot.isBuilding, "A pass that never ran has not finished the first build.")
        }

        func testStopReturnsOnlyOnceTheWorkerHasExited() throws {
            try writeClaudeSession("first", text: "heron migration")
            // The pass's first between-sessions check holds the worker mid-pass until the test lets it go.
            let reachedPass = DispatchSemaphore(value: 0)
            let releaseWorker = DispatchSemaphore(value: 0)
            let checks = LockedCounter()
            let service = makeService(isSuspended: {
                if checks.increment() == 2 {
                    reachedPass.signal()
                    _ = releaseWorker.wait(timeout: .now() + 30)
                }
                return false
            })
            service.start()
            XCTAssertEqual(reachedPass.wait(timeout: .now() + 30), .success)

            let stopReturned = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                service.stop()
                stopReturned.signal()
            }

            XCTAssertEqual(stopReturned.wait(timeout: .now() + 0.3), .timedOut, "stop must wait for the worker that is mid-pass.")
            releaseWorker.signal()
            XCTAssertEqual(stopReturned.wait(timeout: .now() + 30), .success)
            // Nothing holds the index any more, so its files can go without a late write failing.
            try FileManager.default.removeItem(at: root)
            Thread.sleep(forTimeInterval: 0.2)
        }

        func testAStoppedServiceReleasesItsIndexAndANewServiceResumesFromTheFile() throws {
            try writeClaudeSession("first", text: "heron migration")
            let first = makeService()
            first.start()
            try waitUntil("the first build") { try keys(first) == ["first"] }

            first.stop()

            XCTAssertEqual(try keys(first), [], "A stopped service answers nothing.")
            // A daemon that resumes after a failed exec handoff builds a new service over the same file.
            let second = makeService()
            defer { second.stop() }
            second.start()
            try waitUntil("the new service to open the existing index") { try keys(second) == ["first"] }
        }
    }
#endif
