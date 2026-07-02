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

/// Reads and requests the Apple Events automation permission that lets Spaces control Google
/// Chrome. There is no public TCC API to mutate the grant directly; the system consent prompt is
/// raised by `requestAccess()`, and a denied grant is changed only by the user in System Settings.
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

    /// Raises the macOS consent prompt ("Spaces wants to control Google Chrome") when the
    /// permission is still undetermined, and returns the resulting status. Once the user has
    /// denied it, macOS no longer shows the prompt and this returns `.denied`; the caller should
    /// then send the user to System Settings via `systemSettingsAutomationURL`.
    @discardableResult public static func requestAccess() -> ChromeAutomationStatus {
        #if canImport(CoreServices) && !os(Linux)
            return determinePermission(askUserIfNeeded: true)
        #else
            return .unavailable
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
