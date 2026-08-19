import XCTest

@testable import spacesterminalcore

final class TerminalRemoteSessionStateNotificationRoutingTests: XCTestCase {
    /// State changes a mirroring client reacts to with a full pane refresh: runtime state,
    /// attachments/ownership, bootstrap, and termination.
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
    }

    /// `session_metadata` routes to its own notification alone. `TerminalSessionPaneViewController`
    /// observes `.spacesTerminalSessionMetadataDidChange` and `.spacesTerminalRuntimeStateDidChange`
    /// with the identical unconditional `refreshNow()`, so also routing to the runtime-state
    /// notification would refresh the pane twice per title change for no second effect — costly
    /// under a coding agent that rewrites its title many times a second.
    func testSessionMetadataReasonPostsSessionMetadataDidChangeOnly() {
        XCTAssertEqual(
            TerminalRemoteSessionStateNotificationRouting.notifications(forReason: TerminalRemoteSessionStateReason.sessionMetadata),
            [.spacesTerminalSessionMetadataDidChange])
    }

    /// Screen-content reasons arrive at interaction frequency and describe what the mirror
    /// already painted, so they must stay on the output notification — whose observers skip the
    /// refresh while a live Ghostty mirror is on screen.
    func testScreenContentReasonsPostOutputDidChangeOnly() {
        for reason in [
            TerminalRemoteSessionStateReason.output, TerminalRemoteSessionStateReason.input, TerminalRemoteSessionStateReason.inputOutput,
            TerminalRemoteSessionStateReason.stateChange, TerminalRemoteSessionStateReason.scroll, TerminalRemoteSessionStateReason.clearScreen,
            TerminalRemoteSessionStateReason.selection, TerminalRemoteSessionStateReason.resize,
        ] {
            XCTAssertEqual(
                TerminalRemoteSessionStateNotificationRouting.notifications(forReason: reason), [.spacesTerminalOutputDidChange],
                "reason \(reason) must route to the output notification")
        }
    }

    /// A clipboard write changes nothing a pane presents; the receiving client acts on it where it
    /// applies the payload. The row must exist even though it posts nothing, or the unknown-reason
    /// default below would swallow it indistinguishably from a reason nobody registered.
    func testClipboardWriteReasonPostsNothing() {
        XCTAssertEqual(TerminalRemoteSessionStateNotificationRouting.notifications(forReason: TerminalRemoteSessionStateReason.clipboardWrite), [])
    }

    /// A reason this build does not know must not inherit the refresh path.
    func testUnknownReasonPostsNothing() {
        XCTAssertEqual(TerminalRemoteSessionStateNotificationRouting.notifications(forReason: "not_a_reason"), [])
        XCTAssertEqual(TerminalRemoteSessionStateNotificationRouting.notifications(forReason: ""), [])
    }

    /// `isOutputShaped(reason:)` is an allocation-free stand-in for
    /// `notifications(forReason:) == [.spacesTerminalOutputDidChange]`, used on the reduce loop's hot
    /// path (`TerminalRemoteStateReductionOutput.isCoalescibleOnApply`) instead of building the two
    /// `[Notification.Name]` arrays that comparison allocates on every call. The two must never drift:
    /// this checks the predicate against the array comparison it stands in for, across every reason this
    /// table declares plus an unknown one, so a reason added to one side without the other fails here
    /// instead of silently changing what coalesces.
    func testIsOutputShapedStaysConsistentWithNotificationsForReason() {
        let declaredReasons = [
            TerminalRemoteSessionStateReason.initial, TerminalRemoteSessionStateReason.attachmentState,
            TerminalRemoteSessionStateReason.sessionMetadata, TerminalRemoteSessionStateReason.input, TerminalRemoteSessionStateReason.inputOutput,
            TerminalRemoteSessionStateReason.output, TerminalRemoteSessionStateReason.stateChange, TerminalRemoteSessionStateReason.scroll,
            TerminalRemoteSessionStateReason.clearScreen, TerminalRemoteSessionStateReason.selection,
            TerminalRemoteSessionStateReason.runtimeState, TerminalRemoteSessionStateReason.resize,
            TerminalRemoteSessionStateReason.terminated, TerminalRemoteSessionStateReason.clipboardWrite,
        ]
        for reason in declaredReasons + ["not_a_reason", ""] {
            let expected = TerminalRemoteSessionStateNotificationRouting.notifications(forReason: reason) == [.spacesTerminalOutputDidChange]
            XCTAssertEqual(
                TerminalRemoteSessionStateNotificationRouting.isOutputShaped(reason: reason), expected,
                "isOutputShaped(reason: \(reason)) must agree with notifications(forReason:) == [.spacesTerminalOutputDidChange]")
        }
    }
}
