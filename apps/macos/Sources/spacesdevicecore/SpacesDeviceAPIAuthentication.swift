import Foundation

#if canImport(Network)
    import Network
#endif

public enum SpacesDeviceAPIAuthentication {
    public static func recoveryMessage(for error: Error) -> String? {
        if isTransportAuthenticationFailure(error) { return "This Mac no longer recognizes this device. Open Devices and pair this device again." }
        let message = apiMessage(for: error)
        guard isAuthenticationFailure(message: message) else { return nil }
        return "This Mac no longer recognizes this device. Open Devices and pair this device again."
    }

    private static func apiMessage(for error: Error) -> String {
        let localized = error.localizedDescription
        if !localized.isEmpty { return localized }
        return String(describing: error)
    }

    private static func isAuthenticationFailure(message: String) -> Bool {
        message.localizedStandardContains("not paired") || message.localizedStandardContains("invalid device auth token")
            || message.localizedStandardContains("missing device auth token") || message.localizedStandardContains("code=401")
            || message.localizedStandardContains("unauthorized") || message.localizedStandardContains("secure Device API transport")
            || message.localizedStandardContains("Device API transport key")
    }

    private static func isTransportAuthenticationFailure(_ error: Error) -> Bool {
        if error is SpacesDeviceAPITransportError { return true }
        #if canImport(Network)
            guard let networkError = error as? NWError else { return false }
            if case .tls = networkError { return true }
        #endif
        return false
    }
}
