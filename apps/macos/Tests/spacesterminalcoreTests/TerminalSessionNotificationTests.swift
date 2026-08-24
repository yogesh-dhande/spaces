import Foundation
import XCTest
import spacesterminalcore

final class TerminalSessionNotificationTests: XCTestCase {
    /// Captures a synchronously delivered notification across the `@Sendable`
    /// observer boundary imposed by strict concurrency.
    private final class NotificationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Notification?
        func store(_ notification: Notification) {
            lock.lock()
            defer { lock.unlock() }
            stored = notification
        }
        func value() -> Notification? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    /// Counts synchronously delivered notifications across the `@Sendable` observer boundary.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
        }
        func value() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    func testPostCarriesSessionID() throws {
        let box = NotificationBox()
        let name = Notification.Name("spaces.test.notification.\(UUID().uuidString)")
        let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { box.store($0) }
        defer { NotificationCenter.default.removeObserver(token) }

        TerminalSessionNotification.post(name, sessionID: "session-1")

        let notification = try XCTUnwrap(box.value())
        XCTAssertEqual(TerminalSessionNotification.sessionID(from: notification), "session-1")
        XCTAssertEqual(notification.userInfo?["sessionID"] as? String, "session-1")
    }

    /// A pane observes only its own session: the notification center itself must do the filtering, so
    /// another session's post never calls the block out at all.
    func testASessionScopedObserverRunsOnlyForItsOwnSessionsPosts() {
        let name = Notification.Name("spaces.test.notification.\(UUID().uuidString)")
        let mine = Counter()
        let token = TerminalSessionNotification.addObserver(forName: name, sessionID: "session-mine", queue: nil) { mine.increment() }
        defer { NotificationCenter.default.removeObserver(token) }

        TerminalSessionNotification.post(name, sessionID: "session-other")
        XCTAssertEqual(mine.value(), 0, "another session's post must not reach this session's observer")

        TerminalSessionNotification.post(name, sessionID: "session-mine")
        XCTAssertEqual(mine.value(), 1, "this session's post must reach its observer")
    }

    /// The session id a post is scoped by is matched by value. The scope object routing uses is
    /// interned per session id, so a poster holding a different `String` instance with the same
    /// contents (every payload arrives carrying its own) still reaches the observer.
    func testAScopedObserverIsReachedByAnEquivalentSessionIDFromAnotherString() {
        let name = Notification.Name("spaces.test.notification.\(UUID().uuidString)")
        let observed = Counter()
        let token = TerminalSessionNotification.addObserver(forName: name, sessionID: "session-value", queue: nil) { observed.increment() }
        defer { NotificationCenter.default.removeObserver(token) }

        let equivalentSessionID = ["session", "value"].joined(separator: "-")
        TerminalSessionNotification.post(name, sessionID: equivalentSessionID)

        XCTAssertEqual(observed.value(), 1)
    }

    /// Two panes can show the same session, so a second observer for a session id must share the first
    /// one's scope rather than get one only it can be reached by.
    func testEverySessionScopedObserverForOneSessionIsCalled() {
        let name = Notification.Name("spaces.test.notification.\(UUID().uuidString)")
        let first = Counter()
        let second = Counter()
        let firstToken = TerminalSessionNotification.addObserver(forName: name, sessionID: "session-shared", queue: nil) { first.increment() }
        defer { NotificationCenter.default.removeObserver(firstToken) }
        let secondToken = TerminalSessionNotification.addObserver(forName: name, sessionID: "session-shared", queue: nil) { second.increment() }
        defer { NotificationCenter.default.removeObserver(secondToken) }

        TerminalSessionNotification.post(name, sessionID: "session-shared")

        XCTAssertEqual(first.value(), 1)
        XCTAssertEqual(second.value(), 1)
    }

    /// The daemon's reconcilers observe with a `nil` object because they react to any session's change.
    /// Scoping the posts must leave them receiving every one.
    func testAnAllSessionsObserverReceivesEverySessionsPost() {
        let name = Notification.Name("spaces.test.notification.\(UUID().uuidString)")
        let everySession = Counter()
        let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in everySession.increment() }
        defer { NotificationCenter.default.removeObserver(token) }

        TerminalSessionNotification.post(name, sessionID: "session-one")
        TerminalSessionNotification.post(name, sessionID: "session-two")

        XCTAssertEqual(everySession.value(), 2)
    }

    /// A removed observer's session is not kept alive by the registry, and the next observer for that
    /// same session id is still reached: the scope for a session id is re-interned on demand.
    func testASessionIsStillRoutableAfterItsObserverIsRemoved() {
        let name = Notification.Name("spaces.test.notification.\(UUID().uuidString)")
        let firstRun = Counter()
        let firstToken = TerminalSessionNotification.addObserver(forName: name, sessionID: "session-recycled", queue: nil) { firstRun.increment() }
        NotificationCenter.default.removeObserver(firstToken)

        let secondRun = Counter()
        let secondToken = TerminalSessionNotification.addObserver(forName: name, sessionID: "session-recycled", queue: nil) { secondRun.increment() }
        defer { NotificationCenter.default.removeObserver(secondToken) }

        TerminalSessionNotification.post(name, sessionID: "session-recycled")

        XCTAssertEqual(firstRun.value(), 0, "a removed observer must not be called")
        XCTAssertEqual(secondRun.value(), 1)
    }

    func testSessionIDFromReadsDefensively() {
        let missing = Notification(name: Notification.Name("spaces.test.missing"), object: nil, userInfo: nil)
        XCTAssertNil(TerminalSessionNotification.sessionID(from: missing))

        let wrongType = Notification(name: Notification.Name("spaces.test.wrong"), object: nil, userInfo: ["sessionID": 7])
        XCTAssertNil(TerminalSessionNotification.sessionID(from: wrongType))

        let valid = Notification(name: Notification.Name("spaces.test.valid"), object: nil, userInfo: ["sessionID": "session-3"])
        XCTAssertEqual(TerminalSessionNotification.sessionID(from: valid), "session-3")
    }
}
