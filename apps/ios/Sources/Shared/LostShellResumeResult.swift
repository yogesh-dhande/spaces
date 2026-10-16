import Foundation
import spacesdevicecore

/// What asking the device to replace a lost shell produced.
enum LostShellResumeResult: Equatable {
    /// The screen moves to this session in place.
    case replaced(SpacesDeviceTerminalSessionSummary)
    /// The shell's folder is gone: the dead screen stays and says so.
    case folderMissing
    /// No request was sent, or the device refused or failed it: the screen stays as it is.
    case unchanged

    /// This result if the screen that asked is still the one shown, else `.unchanged`. A request outlives
    /// navigation, and applying its result to a screen the user has left would reopen that terminal or
    /// replace whichever one they opened since. The replacement is still reachable from the terminal row.
    func ifStillShown(_ isShown: Bool) -> LostShellResumeResult { isShown ? self : .unchanged }
}
