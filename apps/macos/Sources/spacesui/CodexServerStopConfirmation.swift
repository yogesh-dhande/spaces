import AppKit

/// What the user is shown before Spaces stops Codex's shared background server: stopping ends every Codex
/// session running on it, so the sheet names the device and says the conversations survive.
struct CodexServerStopConfirmation: Equatable {
    let title: String
    let message: String
    let confirmButtonTitle: String

    init(deviceName: String) {
        title = "Stop Codex's background server?"
        message =
            "This ends the Codex sessions running on it on \(deviceName). "
            + "Their conversations are kept, and you can resume them in a Spaces terminal."
        confirmButtonTitle = "Stop Server"
    }

    /// Asks as a sheet on `window`. `onConfirm` runs only when the user picks the stop button.
    @MainActor func present(on window: NSWindow, onConfirm: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmButtonTitle)
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            onConfirm()
        }
    }
}
