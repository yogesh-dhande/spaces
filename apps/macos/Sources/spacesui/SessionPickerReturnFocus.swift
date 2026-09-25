/// The pane the pane session picker (split right/down, ⌘T, the tab strip's "+") returns keyboard focus
/// to when it closes, whether a row was picked or the picker was cancelled. The normal command palette
/// captures its return target from the key window's first responder; the picker names the pane it was
/// opened for instead, because the click that opened it may already have moved the responder. A terminal
/// pane is named by its session id and a code pane by its pane id, the two keys
/// `CommandPaletteController.restoreCommandPaletteReturnFocus` restores focus by.
enum SessionPickerReturnFocus: Equatable, Sendable {
    case terminalSession(sessionID: String)
    case codePane(paneID: String)
}
