import Foundation
import spacesterminalcore

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
            || message.localizedStandardContains("unauthorized") || message.localizedStandardContains("certificate fingerprint")
    }

    private static func isTransportAuthenticationFailure(_ error: Error) -> Bool {
        // A pin mismatch means the daemon's TLS identity no longer matches the fingerprint recorded
        // at pairing time (identity rotated or wrong endpoint) — recoverable only by re-pairing.
        if case TerminalServiceTLSError.certificatePinMismatch = error { return true }
        if case TerminalServiceTLSError.peerCertificateUnavailable = error { return true }
        if case TerminalServiceTLSError.missingCertificateFingerprint = error { return true }
        #if canImport(Network)
            guard let networkError = error as? NWError else { return false }
            if case .tls = networkError { return true }
        #endif
        return false
    }
}
