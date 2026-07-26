import Foundation

#if canImport(CoreServices) && !os(Linux)
    import CoreServices
#endif

/// Whether Spaces is permitted to control Google Chrome through Apple Events (the macOS
/// "Automation" privacy permission). Spaces drives all browser-session focus by scripting
/// Chrome, so this permission gates the browser feature.
public enum ChromeAutomationStatus: String, Sendable, Equatable {
    /// Spaces may send Apple Events to Chrome.
    case granted
    /// The user explicitly denied automation. Only System Settings can re-enable it.
    case denied
    /// The user has not decided yet. Spaces can trigger the system consent prompt.
    case notDetermined
    /// The permission state cannot be read right now (e.g. Chrome is not installed, or Apple
    /// Events are unavailable on this platform). Treated as non-blocking: there is nothing to grant.
    case unavailable
}

/// The result of asking macOS to raise the automation consent prompt, classified so the UI can
/// tell a genuine denial apart from macOS silently refusing to prompt at all.
public enum ChromeAutomationAskOutcome: Sendable, Equatable {
    /// Automation is permitted (or `unavailable`, which is non-blocking): nothing left to gate on.
    case granted
    /// The ask was refused and the passive re-read also reports a denial: a real, recorded "Don't Allow".
    case deniedByUser
    /// The ask was refused, yet the passive re-read still reports `notDetermined`, so macOS never
    /// actually showed the consent prompt. This happens when a stale TCC automation record from a
    /// different code signature is on file: the record's code-signing requirement no longer matches
    /// the running binary, so macOS treats the ask as not-permitted without prompting. Ad-hoc signed
    /// SwiftPM debug builds hit this on every rebuild because their cdhash — the TCC identity — changes
    /// each time. The stale record must be reset (`tccutil reset AppleEvents <bundle id>`) before the
    /// prompt can appear again.
    case promptSuppressed
}

/// Reads and requests the Apple Events automation permission that lets Spaces control Google
/// Chrome. There is no public TCC API to mutate the grant directly; the system consent prompt is
/// raised by `requestAccessOutcome()`, and a denied grant is changed only by the user in System Settings.
public enum ChromeAutomationPermission {
    public static let chromeBundleID = "com.google.Chrome"

    /// System Settings deep link for the Automation privacy pane, used when the permission was
    /// denied (a second consent prompt is not offered after a denial).
    public static let systemSettingsAutomationURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"

    /// Reads the current automation permission for Chrome without prompting the user.
    public static func status() -> ChromeAutomationStatus {
        #if canImport(CoreServices) && !os(Linux)
            return determinePermission(askUserIfNeeded: false)
        #else
            return .unavailable
        #endif
    }

    /// Raises the macOS consent prompt ("Spaces wants to control Google Chrome") when the permission
    /// is still undetermined, and classifies the result. On a refusal it re-reads the passive status
    /// to separate a real user denial (`deniedByUser`) from macOS declining to prompt at all
    /// (`promptSuppressed`) — the latter meaning a stale TCC record blocks the prompt and only a reset
    /// can restore it. `granted` also covers `unavailable`, which is non-blocking.
    public static func requestAccessOutcome() -> ChromeAutomationAskOutcome {
        #if canImport(CoreServices) && !os(Linux)
            switch determinePermission(askUserIfNeeded: true) {
            case .granted, .unavailable: return .granted
            case .denied:
                // The ask was refused. A passive re-read that still says `notDetermined` means macOS
                // never showed the prompt (a stale-signature TCC record suppressed it); a re-read that
                // agrees on `denied` means the user really chose "Don't Allow".
                return status() == .notDetermined ? .promptSuppressed : .deniedByUser
            case .notDetermined:
                // `askUserIfNeeded: true` resolves the undetermined state, so this is not expected;
                // treat it as a suppressed prompt rather than silently advancing.
                return .promptSuppressed
            }
        #else
            return .granted
        #endif
    }

    #if canImport(CoreServices) && !os(Linux)
        private static func determinePermission(askUserIfNeeded: Bool) -> ChromeAutomationStatus {
            guard let bundleIDData = chromeBundleID.data(using: .utf8) else { return .unavailable }
            var target = AEAddressDesc()
            let createStatus = bundleIDData.withUnsafeBytes { rawBuffer in
                AECreateDesc(typeApplicationBundleID, rawBuffer.baseAddress, rawBuffer.count, &target)
            }
            guard createStatus == noErr else { return .unavailable }
            defer { AEDisposeDesc(&target) }
            let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, askUserIfNeeded)
            switch status {
            case noErr: return .granted
            case OSStatus(errAEEventNotPermitted): return .denied
            case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
            default:
                // procNotFound (Chrome not running/installed) and any other error mean the grant
                // cannot be determined now; do not block the app on a permission we cannot verify.
                return .unavailable
            }
        }
    #endif
}
