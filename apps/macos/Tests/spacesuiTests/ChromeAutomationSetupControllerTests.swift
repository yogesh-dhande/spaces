import AppKit
import Foundation
import Testing
import systembridge

@testable import spacesui

/// The Chrome Automation setup screen's state machine. These tests drive it through its injectable
/// status/ask closures and its test hooks (`pollTick`, `performGrantAccess`, `recheck`) so no timer,
/// Apple Event, or AppKit event is involved. They assert behavior — mode, action title, whether
/// `onGranted` fired — never layout internals.
@Suite @MainActor struct ChromeAutomationSetupControllerTests {
    /// Mutable fixture the injected closures read, so a test can change what the "system" reports
    /// between calls. `@unchecked Sendable`: the ask closure runs on a detached task, and the test
    /// body only mutates it while no such task is in flight.
    private final class Fixture: @unchecked Sendable {
        var status: ChromeAutomationStatus
        var askOutcome: ChromeAutomationAskOutcome

        init(status: ChromeAutomationStatus, askOutcome: ChromeAutomationAskOutcome = .granted) {
            self.status = status
            self.askOutcome = askOutcome
        }
    }

    private func makeController(_ fixture: Fixture) -> (ChromeAutomationSetupController, granted: Box<Bool>) {
        let granted = Box(false)
        let controller = ChromeAutomationSetupController(statusProvider: { fixture.status }, askProvider: { fixture.askOutcome })
        controller.onGranted = { granted.value = true }
        return (controller, granted)
    }

    /// A boxed flag so the `@Sendable` `onGranted` closure can record without capturing a `var`.
    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private func actionTitle(_ controller: ChromeAutomationSetupController) -> String {
        // The primary button is the only NSButton with a Return key equivalent in the view.
        let buttons = allSubviews(of: controller.view).compactMap { $0 as? NSButton }
        return buttons.first { $0.keyEquivalent == "\r" }?.title ?? ""
    }

    private func allSubviews(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap { allSubviews(of: $0) } }

    @Test func beginWithNotDeterminedEntersNeedsGrant() {
        let fixture = Fixture(status: .notDetermined)
        let (controller, granted) = makeController(fixture)
        controller.begin()
        #expect(controller.mode == .needsGrant)
        #expect(actionTitle(controller) == "Grant Access")
        #expect(!granted.value)
        controller.stop()
    }

    @Test func beginWithGrantedFiresOnGrantedAndStopsPolling() {
        let fixture = Fixture(status: .granted)
        let (controller, granted) = makeController(fixture)
        controller.begin()
        #expect(granted.value)
        #expect(controller.mode == nil)
        // The step completed, so the auto-advance poll must have been stopped.
        #expect(!controller.isPolling)
    }

    @Test func grantAccessSuppressedPromptDoesNotRevertOnPoll() async {
        // The flip-flop regression: ask refused while the passive read still says notDetermined, so
        // macOS never prompted. The screen must latch `promptSuppressed` and a later poll reading
        // `notDetermined` must not drag it back to `needsGrant`.
        let fixture = Fixture(status: .notDetermined, askOutcome: .promptSuppressed)
        let (controller, _) = makeController(fixture)
        controller.begin()
        await controller.performGrantAccess()
        #expect(controller.mode == .promptSuppressed)
        #expect(actionTitle(controller) == "Open System Settings")

        controller.pollTick()
        #expect(controller.mode == .promptSuppressed)
        #expect(actionTitle(controller) == "Open System Settings")
        controller.stop()
    }

    @Test func grantAccessDeniedByUserEntersDenied() async {
        let fixture = Fixture(status: .denied, askOutcome: .deniedByUser)
        let (controller, granted) = makeController(fixture)
        controller.begin()
        await controller.performGrantAccess()
        #expect(controller.mode == .denied)
        #expect(actionTitle(controller) == "Open System Settings")
        #expect(!granted.value)
        controller.stop()
    }

    @Test func grantAccessGrantedFiresOnGranted() async {
        let fixture = Fixture(status: .notDetermined, askOutcome: .granted)
        let (controller, granted) = makeController(fixture)
        controller.begin()
        await controller.performGrantAccess()
        #expect(granted.value)
    }

    @Test func pollEscalatesNeedsGrantToDenied() {
        let fixture = Fixture(status: .notDetermined)
        let (controller, _) = makeController(fixture)
        controller.begin()
        #expect(controller.mode == .needsGrant)

        fixture.status = .denied
        controller.pollTick()
        #expect(controller.mode == .denied)
        controller.stop()
    }

    @Test func pollDoesNotRevertDeniedToNeedsGrant() async {
        let fixture = Fixture(status: .denied, askOutcome: .deniedByUser)
        let (controller, _) = makeController(fixture)
        controller.begin()
        await controller.performGrantAccess()
        #expect(controller.mode == .denied)

        // Passive read regresses to notDetermined (e.g. a stale record); the latch must hold.
        fixture.status = .notDetermined
        controller.pollTick()
        #expect(controller.mode == .denied)
        controller.stop()
    }

    @Test func pollFiresOnGrantedAndStopsWhenStatusBecomesGranted() {
        let fixture = Fixture(status: .notDetermined)
        let (controller, granted) = makeController(fixture)
        controller.begin()
        #expect(controller.mode == .needsGrant)

        fixture.status = .granted
        controller.pollTick()
        #expect(granted.value)
    }

    @Test func recheckRecoversToNeedsGrantAfterSuppressedPrompt() async {
        // After the user runs `tccutil reset`, the record clears and the passive status reads
        // notDetermined again. Recheck — unlike the poll — is allowed to un-latch the mode.
        let fixture = Fixture(status: .notDetermined, askOutcome: .promptSuppressed)
        let (controller, _) = makeController(fixture)
        controller.begin()
        await controller.performGrantAccess()
        #expect(controller.mode == .promptSuppressed)

        controller.recheck()
        #expect(controller.mode == .needsGrant)
        #expect(actionTitle(controller) == "Grant Access")
        controller.stop()
    }
}
