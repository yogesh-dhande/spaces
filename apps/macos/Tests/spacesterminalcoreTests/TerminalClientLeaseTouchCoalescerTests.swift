import Foundation
import XCTest

@testable import spacesterminalcore

/// The lease-touch coalescing rule: a client's durable lease write happens at most once per coalescing
/// interval, the skipping never lets a live client's lease lapse, and no attachment inherits a previous
/// attachment's write record.
final class TerminalClientLeaseTouchCoalescerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// Typing: a burst of keystrokes inside one interval costs a single durable lease write.
    func testKeystrokeBurstWithinOneIntervalPerformsASingleWrite() {
        var coalescer = TerminalClientLeaseTouchCoalescer()
        var writes = 0
        for keystroke in 0..<200 where coalescer.isDurableTouchDue(clientID: "client", now: start.addingTimeInterval(Double(keystroke) * 0.05)) {
            writes += 1
        }
        XCTAssertEqual(writes, 1, "200 keystrokes spanning 10s must collapse to one durable lease write")
    }

    /// A send after the window writes again, so the durable lease keeps advancing for a client that keeps working.
    func testTouchAfterTheIntervalWritesAgain() {
        var coalescer = TerminalClientLeaseTouchCoalescer()
        XCTAssertTrue(coalescer.isDurableTouchDue(clientID: "client", now: start))
        XCTAssertFalse(
            coalescer.isDurableTouchDue(
                clientID: "client", now: start.addingTimeInterval(TerminalClientLeaseTouchCoalescer.coalescingInterval - 0.001)))
        XCTAssertTrue(
            coalescer.isDurableTouchDue(clientID: "client", now: start.addingTimeInterval(TerminalClientLeaseTouchCoalescer.coalescingInterval)))
    }

    /// The delay a coalesced touch adds is bounded by one interval and cannot compound: writes stay pinned to
    /// multiples of the interval no matter how many touches are skipped in between.
    func testSkippedTouchesDoNotPushTheNextWriteFurtherOut() {
        var coalescer = TerminalClientLeaseTouchCoalescer()
        let interval = TerminalClientLeaseTouchCoalescer.coalescingInterval
        var writeOffsets: [TimeInterval] = []
        // Touches three times per interval for eight intervals: only every third one may write.
        for step in 0..<24 {
            let offset = Double(step) * (interval / 3)
            if coalescer.isDurableTouchDue(clientID: "client", now: start.addingTimeInterval(offset)) { writeOffsets.append(offset) }
        }
        XCTAssertEqual(writeOffsets, (0..<8).map { Double($0) * interval }, "each write must be due one interval after the last write PERFORMED")
    }

    /// Per-client accounting: one client's writes never suppress another's.
    func testEachClientIsCoalescedSeparately() {
        var coalescer = TerminalClientLeaseTouchCoalescer()
        XCTAssertTrue(coalescer.isDurableTouchDue(clientID: "phone", now: start))
        XCTAssertTrue(coalescer.isDurableTouchDue(clientID: "laptop", now: start))
        XCTAssertFalse(coalescer.isDurableTouchDue(clientID: "phone", now: start.addingTimeInterval(1)))
    }

    /// Detach/reattach (and a takeover that runs through the same attach) must not let the new attachment
    /// rest on the old one's write record — its first touch writes.
    func testReattachedClientDoesNotInheritTheWriteRecord() {
        var coalescer = TerminalClientLeaseTouchCoalescer()
        XCTAssertTrue(coalescer.isDurableTouchDue(clientID: "client", now: start))
        coalescer.forget(clientID: "client")
        XCTAssertTrue(
            coalescer.isDurableTouchDue(clientID: "client", now: start.addingTimeInterval(1)),
            "the first touch of a fresh attachment must write, even one second after the previous attachment's write")
    }

    /// Session relaunch detaches every client at once, so no record survives it.
    func testRelaunchDropsEveryClientsWriteRecord() {
        var coalescer = TerminalClientLeaseTouchCoalescer()
        XCTAssertTrue(coalescer.isDurableTouchDue(clientID: "phone", now: start))
        XCTAssertTrue(coalescer.isDurableTouchDue(clientID: "laptop", now: start))
        coalescer.forgetAll()
        XCTAssertTrue(coalescer.isDurableTouchDue(clientID: "phone", now: start.addingTimeInterval(1)))
        XCTAssertTrue(coalescer.isDurableTouchDue(clientID: "laptop", now: start.addingTimeInterval(1)))
    }

    /// A wall-clock step backwards must not park a client's next write beyond the lease: a recorded write
    /// instant in the future makes the touch due again rather than suppressing writes for the length of the jump.
    func testClockStepBackwardsStillWrites() {
        var coalescer = TerminalClientLeaseTouchCoalescer()
        XCTAssertTrue(coalescer.isDurableTouchDue(clientID: "client", now: start))
        XCTAssertTrue(coalescer.isDurableTouchDue(clientID: "client", now: start.addingTimeInterval(-300)))
    }

    /// The behaviour the interval is chosen for: with the daemon's 20s client heartbeat cadence, the durable
    /// lease a coalesced client leaves behind keeps it live at every instant — coalescing never expires a
    /// client that is still there.
    func testCoalescedHeartbeatsKeepALiveClientLiveThroughout() {
        var coalescer = TerminalClientLeaseTouchCoalescer()
        let clientID = "remote-client"
        let heartbeatCadence: TimeInterval = 20
        var durableLeaseRefreshedAt = start
        var elapsed: TimeInterval = 0
        while elapsed <= 600 {
            let now = start.addingTimeInterval(elapsed)
            if elapsed.truncatingRemainder(dividingBy: heartbeatCadence) == 0, coalescer.isDurableTouchDue(clientID: clientID, now: now) {
                durableLeaseRefreshedAt = now
            }
            let snapshot = TerminalSessionAttachmentSnapshot(
                clients: [
                    TerminalClient(
                        id: clientID, kind: .remoteViewer, identity: .init(label: "iPhone"),
                        connectedAt: TerminalSessionTimestamp.string(from: start),
                        leaseRefreshedAt: TerminalSessionTimestamp.string(from: durableLeaseRefreshedAt))
                ],
                attachments: [
                    TerminalAttachment(
                        sessionID: "session-1", clientID: clientID, mode: .viewer, attachedAt: TerminalSessionTimestamp.string(from: start))
                ])
            XCTAssertEqual(
                snapshot.liveAttachments(now: now).map(\.clientID), [clientID],
                "a heartbeating client must stay live at +\(elapsed)s; its coalesced durable lease lapsed")
            elapsed += 1
        }
    }

    /// A client that genuinely dies is still expired, and the detection it costs is bounded by one coalescing
    /// interval — never more.
    func testDeadClientIsStillExpiredWithinOneIntervalOfTheLease() {
        var coalescer = TerminalClientLeaseTouchCoalescer()
        let clientID = "remote-client"
        var durableLeaseRefreshedAt = start
        // The client works for a minute, then vanishes without detaching: its last touch is at +60s.
        var elapsed: TimeInterval = 0
        while elapsed <= 60 {
            if coalescer.isDurableTouchDue(clientID: clientID, now: start.addingTimeInterval(elapsed)) {
                durableLeaseRefreshedAt = start.addingTimeInterval(elapsed)
            }
            elapsed += 0.5
        }
        let lastTouchAt = start.addingTimeInterval(60)
        let snapshot = TerminalSessionAttachmentSnapshot(
            clients: [
                TerminalClient(
                    id: clientID, kind: .remoteViewer, identity: .init(label: "iPhone"), connectedAt: TerminalSessionTimestamp.string(from: start),
                    leaseRefreshedAt: TerminalSessionTimestamp.string(from: durableLeaseRefreshedAt))
            ],
            attachments: [
                TerminalAttachment(
                    sessionID: "session-1", clientID: clientID, mode: .viewer, attachedAt: TerminalSessionTimestamp.string(from: start))
            ])
        let lease = TerminalSessionPersistence.remoteClientLeaseInterval
        let interval = TerminalClientLeaseTouchCoalescer.coalescingInterval
        XCTAssertTrue(
            snapshot.liveAttachments(now: lastTouchAt.addingTimeInterval(lease + interval)).isEmpty,
            "a vanished client must be expired within one coalescing interval past the lease")
        XCTAssertEqual(
            snapshot.liveAttachments(now: lastTouchAt.addingTimeInterval(lease - 1)).map(\.clientID), [clientID],
            "expiry must not fire before the lease itself elapses")
    }
}
