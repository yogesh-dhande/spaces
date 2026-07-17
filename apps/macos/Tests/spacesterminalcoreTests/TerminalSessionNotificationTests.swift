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

    func testSessionIDFromReadsDefensively() {
        let missing = Notification(name: Notification.Name("spaces.test.missing"), object: nil, userInfo: nil)
        XCTAssertNil(TerminalSessionNotification.sessionID(from: missing))

        let wrongType = Notification(name: Notification.Name("spaces.test.wrong"), object: nil, userInfo: ["sessionID": 7])
        XCTAssertNil(TerminalSessionNotification.sessionID(from: wrongType))

        let valid = Notification(name: Notification.Name("spaces.test.valid"), object: nil, userInfo: ["sessionID": "session-3"])
        XCTAssertEqual(TerminalSessionNotification.sessionID(from: valid), "session-3")
    }
}
