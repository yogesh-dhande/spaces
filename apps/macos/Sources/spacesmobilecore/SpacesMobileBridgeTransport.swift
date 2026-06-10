import Foundation

#if canImport(Network)
    import Network
#endif
#if canImport(Security)
    import Security
#endif

public enum SpacesMobileBridgeTransportRole: Sendable {
    case server
    case client
}

public enum SpacesMobileBridgeTransportError: LocalizedError, Equatable {
    case missingTransportKey
    case invalidTransportKey

    public var errorDescription: String? {
        switch self {
        case .missingTransportKey: "The mobile bridge transport key is missing."
        case .invalidTransportKey: "The mobile bridge transport key is invalid."
        }
    }
}

public enum SpacesMobileBridgeTransport {
    public static let pskIdentity = "spaces-mobile-v1"

    #if canImport(Network) && canImport(Security)
        public static func parameters(transportKey: String, role: SpacesMobileBridgeTransportRole) throws -> NWParameters {
            let keyData = try decodeTransportKey(transportKey)
            let identityData = Data(pskIdentity.utf8)
            let tlsOptions = NWProtocolTLS.Options()
            let securityOptions = tlsOptions.securityProtocolOptions
            sec_protocol_options_set_min_tls_protocol_version(securityOptions, .TLSv12)
            sec_protocol_options_set_max_tls_protocol_version(securityOptions, .TLSv13)
            sec_protocol_options_set_peer_authentication_required(securityOptions, false)
            sec_protocol_options_add_pre_shared_key(securityOptions, dispatchData(from: keyData), dispatchData(from: identityData))
            switch role {
            case .server: sec_protocol_options_set_tls_pre_shared_key_identity_hint(securityOptions, dispatchData(from: identityData))
            case .client:
                sec_protocol_options_set_pre_shared_key_selection_block(
                    securityOptions, { _, _, complete in complete(dispatchData(from: identityData)) }, DispatchQueue.global(qos: .userInitiated))
            }
            return NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        }
    #endif

    public static func decodeTransportKey(_ value: String) throws -> Data {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SpacesMobileBridgeTransportError.missingTransportKey }
        var base64 = trimmed.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64.append(String(repeating: "=", count: 4 - remainder)) }
        guard let data = Data(base64Encoded: base64), data.count >= 32 else { throw SpacesMobileBridgeTransportError.invalidTransportKey }
        return data
    }

    public static func encodeTransportKey(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(
            of: "=", with: "")
    }

    #if canImport(Network) && canImport(Security)
        private static func dispatchData(from data: Data) -> dispatch_data_t {
            data.withUnsafeBytes { rawBuffer in DispatchData(bytes: rawBuffer) as dispatch_data_t }
        }
    #endif
}
