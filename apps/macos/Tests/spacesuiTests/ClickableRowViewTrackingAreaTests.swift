import AppKit
import Testing

@testable import spacesui

/// `ClickableRowView.updateTrackingAreas` used to remove every tracking area on the view before adding
/// its own hover area back, which also discarded AppKit's own tooltip tracking area (installed by
/// setting `toolTip`) on the next update, silently losing the offline-device tooltip after any resize or
/// scroll. This suite cannot drive AppKit's real tooltip-tracking-area installation headlessly (it needs
/// a live window/tooltip manager), so it proves the underlying mechanic instead: a foreign tracking area
/// already on the view, standing in for one AppKit or another owner installed, survives
/// `updateTrackingAreas()` untouched, while the view's own hover area is still replaced (not duplicated).
@Suite @MainActor struct ClickableRowViewTrackingAreaTests {
    @Test func updateTrackingAreasReplacesOnlyItsOwnHoverAreaAndLeavesAForeignOneAlone() {
        let view = ClickableRowView(isInteractive: true)
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 30)

        let foreignOwner = NSObject()
        let foreignArea = NSTrackingArea(
            rect: view.bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: foreignOwner, userInfo: nil)
        view.addTrackingArea(foreignArea)

        view.updateTrackingAreas()
        #expect(view.trackingAreas.contains(foreignArea), "a tracking area the view did not add itself must survive the first update")
        #expect(view.trackingAreas.count == 2, "the foreign area plus exactly one hover area")

        // A second update (what a resize or scroll drives) must not accumulate hover areas or touch the
        // foreign one.
        view.updateTrackingAreas()
        #expect(view.trackingAreas.contains(foreignArea), "a tracking area the view did not add itself must survive a later update")
        #expect(view.trackingAreas.count == 2, "the hover area is replaced, not accumulated, across repeated updates")
    }

    /// A non-interactive row has no hover area to replace, so a foreign tracking area (standing in for
    /// AppKit's tooltip area) is the only one left after an update.
    @Test func updateTrackingAreasOnANonInteractiveRowLeavesAForeignAreaAlone() {
        let view = ClickableRowView(isInteractive: false)
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 30)

        let foreignOwner = NSObject()
        let foreignArea = NSTrackingArea(
            rect: view.bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: foreignOwner, userInfo: nil)
        view.addTrackingArea(foreignArea)

        view.updateTrackingAreas()

        #expect(view.trackingAreas == [foreignArea])
    }
}
