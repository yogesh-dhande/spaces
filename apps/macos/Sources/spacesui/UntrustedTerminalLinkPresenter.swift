#if canImport(AppKit)
    import AppKit
    import Foundation
    import spacesdevicecore

    /// Presents the two non-silent outcomes of `SpacesUntrustedTerminalLink` for a link a program printed.
    /// A protocol so `TerminalLinkOpenCoordinator`'s tests can record the outcome without a modal.
    @MainActor protocol UntrustedTerminalLinkPresenting: AnyObject {
        /// Asks before a link with a custom scheme is handed to whatever application registered for it.
        /// `open` runs only if the user confirms.
        func presentConfirmation(for url: URL, displayString: String, open: @escaping @MainActor () -> Void)
        /// Tells the user a link was refused and why, offering a copy of the sanitized target.
        func presentBlock(reason: SpacesUntrustedTerminalLink.DenialReason, displayString: String)
    }

    /// The alerts Ghostty's own macOS app shows for the same outcomes, with its copy.
    @MainActor final class UntrustedTerminalLinkAlertPresenter: UntrustedTerminalLinkPresenting {
        func presentConfirmation(for url: URL, displayString: String, open: @escaping @MainActor () -> Void) {
            let handler =
                NSWorkspace.shared.urlForApplication(toOpen: url).map { "\u{201C}\($0.deletingPathExtension().lastPathComponent)\u{201D}" }
                ?? "the default application"
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.icon = NSImage(named: NSImage.cautionName)
            alert.messageText = "Open Link from Terminal Output?"
            alert.informativeText = "This link will open in \(handler). Only continue if you recognize and trust the destination."
            alert.accessoryView = Self.targetView(displayString)
            // Cancel is first, so it is the default button.
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Open Link")
            present(alert) { response in
                guard response == .alertSecondButtonReturn else { return }
                open()
            }
        }

        func presentBlock(reason: SpacesUntrustedTerminalLink.DenialReason, displayString: String) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.icon = NSImage(named: NSImage.cautionName)
            alert.messageText = "Blocked This Link"
            alert.informativeText = reason.message
            alert.accessoryView = Self.targetView(displayString)
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Copy Link")
            present(alert) { response in
                // The sanitized target is what gets copied, so the explicit way forward is a paste the
                // user makes themselves, never a one-click bypass of the block.
                guard response == .alertSecondButtonReturn else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(displayString, forType: .string)
            }
        }

        /// The click that raised the link arrives from Ghostty's action callback with the renderer lock
        /// held, so the modal waits for the next main-loop turn instead of re-entering a render callback.
        private func present(_ alert: NSAlert, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
            Task { @MainActor in
                if let window = NSApp.keyWindow { completion(await alert.beginSheetModal(for: window)) } else { completion(alert.runModal()) }
            }
        }

        private static func targetView(_ target: String) -> NSView {
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 96))
            scrollView.borderType = .bezelBorder
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true

            let textView = NSTextView(frame: scrollView.contentView.bounds)
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            textView.textContainerInset = NSSize(width: 6, height: 6)
            textView.string = target
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
            scrollView.documentView = textView
            return scrollView
        }
    }
#endif
