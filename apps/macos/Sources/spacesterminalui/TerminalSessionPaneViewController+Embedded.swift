import AppKit
import Foundation
import spacesterminalcore

/// Embedded (panel) hosting lifecycle: the pane lives inside an app-managed container
/// view instead of its own `NSWindow`, so the window shell's presentation concerns
/// (frame restore, ordering front, deferred first-present) do not apply. These are the
/// window shell's `show`/`windowWillClose`/focus flows reduced to their content parts.
extension TerminalSessionPaneViewController {
    /// Prepares and attaches the pane's content for display inside a container view:
    /// refreshes state, attaches the local client, and brings the Ghostty host up.
    /// `focus` additionally moves keyboard focus into the terminal.
    public func showEmbedded(requestID: String? = nil, focus: Bool) {
        stateProvider.refreshState()
        didCloseWindow = false
        if let launchConfiguration { updateGhosttySessionHostReference(for: launchConfiguration) }
        refreshRuntimeStateFromProvider()
        if backend != .ghosttyEmbedded || canAttachToGhosttyRuntime(lastObservedRuntimeState) {
            attachLocalClientIfNeeded(mode: initialAttachmentModeForShow())
        }
        refreshNow(allowGhosttyOwnerAttach: false)
        if backend == .ghosttyEmbedded, canAttachToGhosttyRuntime(lastObservedRuntimeState) {
            ensureGhosttyHostAttached(requestID: requestID, reason: "embedded_show", requestWindowFocus: focus)
        }
        refreshNow()
        if focus { focusEmbeddedTerminalInput() }
    }

    /// Moves keyboard focus into the terminal content.
    public func focusEmbeddedTerminalInput() {
        assignPreferredFirstResponder()
        syncGhosttyOwnerFocus(reason: "embedded_focus", requestWindowFocus: true)
    }

    /// Marks the pane hidden while it stays alive (its tab switched away): drops owner
    /// focus without detaching, so switching back is instant.
    public func hideEmbedded() {
        syncGhosttyOwnerFocus(reason: "embedded_hidden", requestWindowFocus: false, focused: false)
    }

    /// Whether `responder` lives inside this pane's view tree. Drives focused-pane
    /// tracking from window first-responder changes.
    public func ownsResponder(_ responder: NSResponder) -> Bool {
        var current = responder as? NSView
        while let candidate = current {
            if candidate === view { return true }
            current = candidate.superview
        }
        return false
    }

    /// Tears the pane down when it is explicitly closed — the embedded equivalent of
    /// the window shell's `windowWillClose`: release the renderer surface, detach the
    /// local client, and notify the close callback.
    public func closeEmbedded(sessionIsTerminating: Bool = false) {
        guard !didCloseWindow else { return }
        didCloseWindow = true
        TerminalPerformance.logMetric(
            "terminal_pane_close", target: "session=\(sessionID)", elapsedMS: 0, success: true,
            detail: "client=\(clientID) terminating=\(sessionIsTerminating ? 1 : 0)")
        if backend == .ghosttyEmbedded {
            syncGhosttyOwnerFocus(reason: "embedded_close", requestWindowFocus: false, focused: false)
            if !sessionIsTerminating { ghosttyRendererHost?.releaseRendererSurface() }
        }
        if sessionIsTerminating {
            isClientAttached = false
            lastRequestedAttachmentMode = nil
        } else {
            // Run the close hook off the detach's completion (not synchronously here): the async
            // detach only lands after a daemon round-trip, so the owner's ad hoc cleanup must wait
            // for it to read a snapshot that reflects this client leaving. A session-terminating
            // close skips it — the daemon is already stopping the session.
            detachLocalClientIfNeeded(synchronously: detachClientSynchronouslyOnClose, onDetached: onCloseClientDetached)
        }
        onWindowClose?(sessionID, clientID, sessionIsTerminating)
    }
}
