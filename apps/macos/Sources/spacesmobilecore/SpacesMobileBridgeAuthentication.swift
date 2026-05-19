import Foundation

public enum SpacesMobileBridgeAuthentication {
    public static func recoveryMessage(for error: Error) -> String? {
        let message = bridgeMessage(for: error)
        guard isAuthenticationFailure(message: message) else { return nil }
        return "This Mac no longer recognizes this device. Open Connection and pair this device again."
    }

    private static func bridgeMessage(for error: Error) -> String {
        let localized = error.localizedDescription
        if !localized.isEmpty { return localized }
        return String(describing: error)
    }

    private static func isAuthenticationFailure(message: String) -> Bool {
        message.localizedStandardContains("not paired") || message.localizedStandardContains("invalid mobile auth token")
            || message.localizedStandardContains("missing mobile auth token") || message.localizedStandardContains("code=401")
            || message.localizedStandardContains("unauthorized")
    }
}
