import AppKit
import Foundation
import spacesterminalcore
import spacesterminalghostty

extension TerminalSessionWindowController {
    public func windowWillClose(_ notification: Notification) {
        let sessionIsTerminating = closesForSessionTermination
        closesForSessionTermination = false
        pane.didCloseWindow = true
        hasTestWindowPresentation = false
        TerminalPerformance.logMetric(
            "terminal_window_will_close", target: "session=\(sessionID)", elapsedMS: 0, success: true,
            detail: "client=\(pane.clientID) terminating=\(sessionIsTerminating ? 1 : 0)")
        persistCurrentWindowFrame(immediately: true)
        if pane.backend == .ghosttyEmbedded {
            pane.syncGhosttyOwnerFocus(reason: "window_close", requestWindowFocus: false, focused: false)
            if !sessionIsTerminating { pane.ghosttyRendererHost?.releaseRendererSurface() }
        }
        if sessionIsTerminating {
            pane.isClientAttached = false
            pane.lastRequestedAttachmentMode = nil
        } else {
            pane.detachLocalClientIfNeeded(synchronously: pane.detachClientSynchronouslyOnClose)
        }
        pane.onWindowClose?(sessionID, pane.clientID, sessionIsTerminating)
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        pane.onWindowFocus?(sessionID)
        completePendingFocusObservationIfNeeded(reason: "window_key")
        pane.syncGhosttyOwnerFocus(reason: "window_key", requestWindowFocus: true)
    }

    public func windowDidResignKey(_ notification: Notification) {
        pane.syncGhosttyOwnerFocus(reason: "window_key_lost", requestWindowFocus: false, focused: false)
    }

    public func windowDidBecomeMain(_ notification: Notification) {
        pane.onWindowFocus?(sessionID)
        completePendingFocusObservationIfNeeded(reason: "window_main")
        pane.syncGhosttyOwnerFocus(reason: "window_main", requestWindowFocus: true)
    }

    public func windowDidResignMain(_ notification: Notification) {
        pane.syncGhosttyOwnerFocus(reason: "window_main_lost", requestWindowFocus: false, focused: false)
    }

    public func windowDidMove(_ notification: Notification) { persistCurrentWindowFrame() }

    public func windowDidResize(_ notification: Notification) {
        persistCurrentWindowFrame()
        pane.syncGhosttyOwnerFocus(reason: "window_resize", requestWindowFocus: false)
    }

    public func windowDidEndLiveResize(_ notification: Notification) {
        persistCurrentWindowFrame(immediately: true)
        pane.syncGhosttyOwnerFocus(reason: "window_resize_end", requestWindowFocus: true)
    }

    func isWindowPresented(_ window: NSWindow) -> Bool {
        if Self.isRunningUnderXCTest { return hasTestWindowPresentation }
        return window.isVisible
    }

    nonisolated static func shouldRetryWindowActivation(
        forceFrontmost: Bool, appWasActive: Bool, windowIsKeyAfterInitialActivation: Bool, isDeferredOwnerPresentation: Bool, takeoverPending: Bool
    ) -> Bool {
        guard forceFrontmost || !appWasActive else { return false }
        return isDeferredOwnerPresentation || takeoverPending || !windowIsKeyAfterInitialActivation
    }

    func presentWindow(_ window: NSWindow, forceFrontmost: Bool = false, isDeferredOwnerPresentation: Bool = false) {
        if Self.isRunningUnderXCTest {
            hasTestWindowPresentation = true
            return
        }
        let appWasActive = NSApp.isActive
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        guard
            Self.shouldRetryWindowActivation(
                forceFrontmost: forceFrontmost, appWasActive: appWasActive, windowIsKeyAfterInitialActivation: window.isKeyWindow,
                isDeferredOwnerPresentation: isDeferredOwnerPresentation, takeoverPending: pane.takeoverTask != nil)
        else { return }
        window.orderFrontRegardless()
        Task { @MainActor [weak window] in
            await Task.yield()
            guard let window, window.isVisible, !window.isMiniaturized else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func presentWindowWithoutActivating(_ window: NSWindow) {
        if Self.isRunningUnderXCTest {
            hasTestWindowPresentation = true
            return
        }
        window.orderFront(nil)
    }

    func constrainWindowToVisibleFrame(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame.insetBy(dx: 24, dy: 24)
        var frame = window.frame
        frame.size.width = min(frame.width, visibleFrame.width)
        frame.size.height = min(frame.height, visibleFrame.height)
        frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), visibleFrame.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - frame.height)
        window.setFrame(frame, display: false)
    }

    func restorePersistedWindowFrame(_ window: NSWindow) {
        guard let frame = try? loadWindowFrameAction(pane.preferredAttachmentMode) else { return }
        let restoredFrame = NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        guard restoredFrame.width >= window.minSize.width, restoredFrame.height >= window.minSize.height else { return }
        window.setFrame(restoredFrame, display: false)
    }

    private func persistCurrentWindowFrame(immediately: Bool = false) {
        pendingWindowFramePersistTask?.cancel()
        if immediately {
            writeCurrentWindowFrame()
            return
        }
        pendingWindowFramePersistTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            self?.writeCurrentWindowFrame()
        }
    }

    private func writeCurrentWindowFrame() {
        guard let window else { return }
        let frame = window.frame
        let persistedFrame = TerminalSessionWindowFrame(x: frame.origin.x, y: frame.origin.y, width: frame.size.width, height: frame.size.height)
        try? saveWindowFrameAction(persistedFrame, pane.preferredAttachmentMode)
    }
}
