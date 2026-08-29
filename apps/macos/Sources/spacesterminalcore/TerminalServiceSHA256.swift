import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#endif
#if canImport(OpenSSL)
    import OpenSSL
#endif

/// Cross-platform SHA-256 over raw bytes. `spacesterminalcore` owns the direct CryptoKit/OpenSSL
/// dependencies, so higher-level targets can share one implementation without importing either
/// crypto module themselves.
public enum TerminalServiceSHA256 {
    public static func hexDigest(_ data: Data) -> String {
        #if canImport(CryptoKit)
            let digest = SHA256.hash(data: data)
            return digest.map { String(format: "%02x", $0) }.joined()
        #elseif canImport(OpenSSL)
            var digest = [UInt8](repeating: 0, count: Int(SHA256_DIGEST_LENGTH))
            if data.isEmpty {
                // `Data().withUnsafeBytes` yields a nil base address on Linux. Pass a real unused byte
                // with length 0 so OpenSSL still computes SHA-256's defined empty-input digest.
                var unusedByte: UInt8 = 0
                _ = OpenSSL.SHA256(&unusedByte, 0, &digest)
            } else {
                data.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                    _ = OpenSSL.SHA256(baseAddress, data.count, &digest)
                }
            }
            return digest.map { String(format: "%02x", $0) }.joined()
        #else
            preconditionFailure("TerminalServiceSHA256 requires SHA-256 support.")
        #endif
    }
}
