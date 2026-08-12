import Foundation
import spacesterminalcore

/// An error that carries a machine-readable Spaces failure category. Auth-failure classification
/// branches on the code when present instead of substring-matching the message; errors without a
/// code (raw transport failures) fall through to the message heuristics.
public protocol SpacesDeviceErrorCodeProviding { var spacesDeviceErrorCode: SpacesDeviceErrorCode? { get } }

public enum SpacesDeviceAPIAuthentication {
    private static let reAuthenticationMessage = "This Mac no longer recognizes this device. Open Devices and pair this device again."

    public static func recoveryMessage(for error: Error) -> String? {
        if isTransportAuthenticationFailure(error) { return reAuthenticationMessage }
        // A daemon response that carries a category is authoritative: branch on it directly and do
        // not fall back to message substrings. Errors without a code (raw transport failures) still
        // route through the message heuristics below.
        if let coded = error as? SpacesDeviceErrorCodeProviding, let code = coded.spacesDeviceErrorCode {
            return isAuthenticationFailure(code: code) ? reAuthenticationMessage : nil
        }
        let message = apiMessage(for: error)
        guard isAuthenticationFailure(message: message) else { return nil }
        return reAuthenticationMessage
    }

    public static func isAuthenticationFailure(code: SpacesDeviceErrorCode?) -> Bool { code == .unauthorized }

    private static func apiMessage(for error: Error) -> String {
        let localized = error.localizedDescription
        if !localized.isEmpty { return localized }
        return String(describing: error)
    }

    private static func isAuthenticationFailure(message: String) -> Bool {
        message.localizedStandardContains("not paired") || message.localizedStandardContains("invalid device auth token")
            || message.localizedStandardContains("missing device auth token") || message.localizedStandardContains("unauthorized")
            || message.localizedStandardContains("certificate fingerprint")
            // The iOS client reports a reachable port whose pinned-TLS handshake never completes as
            // "The secure Device API transport could not authenticate." That means the daemon's TLS
            // identity no longer matches the pinned fingerprint (rotated or wrong endpoint), which is
            // recoverable only by re-pairing — route it into the same recovery flow.
            || message.localizedStandardContains("secure Device API transport")
    }

    /// The single authority for "this transport error means the pinned identity did not check out".
    /// Used both here, to compose the re-pair recovery message, and by
    /// `SpacesDeviceEndpointResolver.attempt` on iOS, to classify a candidate's failed connect attempt
    /// as a pin mismatch during the multi-address race. Keeping one definition means a transport error
    /// shape recognized in one place is automatically recognized in the other, rather than the two
    /// call sites drifting out of sync over what counts as an authentication failure.
    public static func isTransportAuthenticationFailure(_ error: Error) -> Bool {
        // A pin mismatch means the daemon's TLS identity no longer matches the fingerprint recorded
        // at pairing time (identity rotated or wrong endpoint) — recoverable only by re-pairing.
        if case TerminalServiceTLSError.certificatePinMismatch = error { return true }
        if case TerminalServiceTLSError.peerCertificateUnavailable = error { return true }
        if case TerminalServiceTLSError.missingCertificateFingerprint = error { return true }
        // The endpoint resolver's verdict for a candidate that accepts TCP but never completes the
        // pinned handshake: something is listening there, and it is not the daemon this client pinned.
        if case SpacesDeviceEndpointResolverError.transportAuthenticationFailed = error { return true }
        // Deliberately no `NWError.tls` catch-all. That case covers every TLS-layer transport failure,
        // including a handshake aborted or reset under a suspended process, a captive portal cutting the
        // connection, and an interface still coming up on foreground resume. Treating those as a
        // rejected pin sent the app into re-pair recovery for failures the next request recovers from on
        // its own. Identity is decided by the pinned verify block: callers that drive their own
        // connections carry its verdict in a `SpacesPinnedTLSPinRejection` and rethrow the
        // `TerminalServiceTLSError` recognized above, so a genuine pin rejection still lands here.
        return false
    }
}
