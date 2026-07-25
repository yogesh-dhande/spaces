import XCTest

@testable import spacesterminalcore

final class TerminalRemoteSessionStateNotificationRoutingTests: XCTestCase {
    /// State changes a mirroring client reacts to with a full pane refresh: runtime state,
    /// attachments/ownership, session metadata, bootstrap, and termination.
    func testStateShapedReasonsPostRuntimeStateDidChange() {
        XCTAssertEqual(
            TerminalRemoteSessionStateNotificationRouting.notifications(forReason: TerminalRemoteSessionStateReason.initial),
            [.spacesTerminalRuntimeStateDidChange])
        XCTAssertEqual(
            TerminalRemoteSessionStateNotificationRouting.notifications(forReason: TerminalRemoteSessionStateReason.runtimeState),
            [.spacesTerminalRuntimeStateDidChange])
        XCTAssertEqual(
            TerminalRemoteSessionStateNotificationRouting.notifications(forReason: TerminalRemoteSessionStateReason.terminated),
            [.spacesTerminalRuntimeStateDidChange])
        XCTAssertEqual(
            TerminalRemoteSessionStateNotificationRouting.notifications(forReason: TerminalRemoteSessionStateReason.attachmentState),
            [.spacesTerminalAttachmentStateDidChange, .spacesTerminalRuntimeStateDidChange])
        XCTAssertEqual(
            TerminalRemoteSessionStateNotificationRouting.notifications(forReason: TerminalRemoteSessionStateReason.sessionMetadata),
            [.spacesTerminalSessionMetadataDidChange, .spacesTerminalRuntimeStateDidChange])
    }

    /// Screen-content reasons arrive at interaction frequency and describe what the mirror
    /// already painted, so they must stay on the output notification — whose observers skip the
    /// refresh while a live Ghostty mirror is on screen.
    func testScreenContentReasonsPostOutputDidChangeOnly() {
        for reason in [
            TerminalRemoteSessionStateReason.output, TerminalRemoteSessionStateReason.input, TerminalRemoteSessionStateReason.inputOutput,
            TerminalRemoteSessionStateReason.stateChange, TerminalRemoteSessionStateReason.scroll, TerminalRemoteSessionStateReason.clearScreen,
            TerminalRemoteSessionStateReason.resize,
        ] {
            XCTAssertEqual(
                TerminalRemoteSessionStateNotificationRouting.notifications(forReason: reason), [.spacesTerminalOutputDidChange],
                "reason \(reason) must route to the output notification")
        }
    }

    /// A reason this build does not know must not inherit the refresh path.
    func testUnknownReasonPostsNothing() {
        XCTAssertEqual(TerminalRemoteSessionStateNotificationRouting.notifications(forReason: "not_a_reason"), [])
        XCTAssertEqual(TerminalRemoteSessionStateNotificationRouting.notifications(forReason: ""), [])
    }
}
