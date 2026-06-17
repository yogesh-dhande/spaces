import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#endif

public struct RemoteSpacesArtifact: Codable, Sendable, Equatable, Identifiable {
    private enum CodingKeys: String, CodingKey {
        case id
        case version
        case platform
        case architecture
        case archiveName = "archive_name"
        case url
        case sha256
    }

    public let id: String
    public let version: String
    public let platform: String
    public let architecture: String
    public let archiveName: String
    public let url: String
    public let sha256: String

    public init(id: String, version: String, platform: String, architecture: String, archiveName: String, url: String, sha256: String) {
        self.id = id
        self.version = version
        self.platform = platform
        self.architecture = architecture
        self.archiveName = archiveName
        self.url = url
        self.sha256 = sha256.lowercased()
    }
}

public struct RemoteSpacesArtifactManifest: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case appVersion = "app_version"
        case releaseTag = "release_tag"
        case artifacts
    }

    public let schemaVersion: Int
    public let appVersion: String
    public let releaseTag: String
    public let artifacts: [RemoteSpacesArtifact]

    public init(schemaVersion: Int = 1, appVersion: String, releaseTag: String, artifacts: [RemoteSpacesArtifact]) {
        self.schemaVersion = schemaVersion
        self.appVersion = appVersion
        self.releaseTag = releaseTag
        self.artifacts = artifacts
    }
}

public struct RemoteSpacesPlatformProbe: Sendable, Equatable {
    public let operatingSystem: String
    public let architecture: String
    public let macOSVersion: String?
    public let linuxID: String?
    public let linuxVersionID: String?

    public init(operatingSystem: String, architecture: String, macOSVersion: String? = nil, linuxID: String? = nil, linuxVersionID: String? = nil) {
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.macOSVersion = macOSVersion
        self.linuxID = linuxID
        self.linuxVersionID = linuxVersionID
    }

    public static func parse(_ output: String) -> RemoteSpacesPlatformProbe {
        var values: [String: String] = [:]
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let parts = rawLine.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            values[String(parts[0])] = String(parts[1])
        }
        return RemoteSpacesPlatformProbe(
            operatingSystem: values["os"] ?? "", architecture: values["arch"] ?? "", macOSVersion: normalized(values["macos_version"]),
            linuxID: normalized(values["linux_id"]), linuxVersionID: normalized(values["linux_version_id"]))
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

public enum RemoteSpacesArtifactError: LocalizedError, Equatable {
    case unsupportedPlatform(RemoteSpacesPlatformProbe)
    case artifactNotFound(id: String, version: String)
    case invalidManifestSchema(Int)
    case invalidManifestVersion(expected: String, actual: String)
    case invalidPublicKey
    case invalidSignature
    case cryptographyUnavailable
    case checksumMismatch(expected: String, actual: String)
    case invalidManifestURL(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform(let probe):
            let details = [probe.operatingSystem, probe.linuxID, probe.linuxVersionID, probe.macOSVersion, probe.architecture].compactMap {
                value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }.joined(separator: " ")
            return
                "Remote host platform is not supported: \(details.isEmpty ? "unknown" : details). Spaces supports macOS 14+ universal remotes and Ubuntu 24.04 on x86_64 or arm64."
        case .artifactNotFound(let id, let version): return "Remote artifact \(id) was not found in the signed manifest for Spaces \(version)."
        case .invalidManifestSchema(let schema): return "Remote artifact manifest schema \(schema) is not supported."
        case .invalidManifestVersion(let expected, let actual): return "Remote artifact manifest version \(actual) does not match Spaces \(expected)."
        case .invalidPublicKey: return "The Spaces remote artifact signing public key is not configured."
        case .invalidSignature: return "The Spaces remote artifact manifest signature is invalid."
        case .cryptographyUnavailable: return "Remote artifact signature verification is unavailable in this build."
        case .checksumMismatch(let expected, let actual): return "Remote artifact checksum mismatch. Expected \(expected), got \(actual)."
        case .invalidManifestURL(let url): return "Remote artifact manifest URL is invalid: \(url)"
        }
    }
}

public enum RemoteSpacesArtifactSelector {
    public static func select(manifest: RemoteSpacesArtifactManifest, for probe: RemoteSpacesPlatformProbe, appVersion: String = AppVersion.current)
        throws -> RemoteSpacesArtifact
    {
        guard manifest.schemaVersion == 1 else { throw RemoteSpacesArtifactError.invalidManifestSchema(manifest.schemaVersion) }
        guard manifest.appVersion == appVersion else {
            throw RemoteSpacesArtifactError.invalidManifestVersion(expected: appVersion, actual: manifest.appVersion)
        }
        let artifactID = try artifactID(for: probe)
        guard let artifact = manifest.artifacts.first(where: { $0.id == artifactID }) else {
            throw RemoteSpacesArtifactError.artifactNotFound(id: artifactID, version: appVersion)
        }
        return artifact
    }

    public static func artifactID(for probe: RemoteSpacesPlatformProbe) throws -> String {
        let os = probe.operatingSystem.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let arch = normalizedArchitecture(probe.architecture)
        if os == "darwin" {
            guard macOSIsSupported(probe.macOSVersion), arch == "x86_64" || arch == "arm64" else {
                throw RemoteSpacesArtifactError.unsupportedPlatform(probe)
            }
            return "spacesd-macos-universal"
        }
        if os == "linux", probe.linuxID?.lowercased() == "ubuntu", probe.linuxVersionID == "24.04" {
            switch arch {
            case "x86_64": return "spacesd-ubuntu-24.04-x86_64"
            case "arm64": return "spacesd-ubuntu-24.04-arm64"
            default: break
            }
        }
        throw RemoteSpacesArtifactError.unsupportedPlatform(probe)
    }

    public static func normalizedArchitecture(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "amd64", "x64": return "x86_64"
        case "aarch64": return "arm64"
        default: return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    private static func macOSIsSupported(_ value: String?) -> Bool {
        guard let major = value?.split(separator: ".").first.flatMap({ Int($0) }) else { return false }
        return major >= 14
    }
}

public enum RemoteSpacesArtifactManifestVerifier {
    public static func decodeVerifiedManifest(manifestData: Data, signature: Data, publicKey: String, appVersion: String = AppVersion.current) throws
        -> RemoteSpacesArtifactManifest
    {
        try verifySignature(message: manifestData, signature: signature, publicKey: publicKey)
        let manifest = try JSONDecoder().decode(RemoteSpacesArtifactManifest.self, from: manifestData)
        guard manifest.schemaVersion == 1 else { throw RemoteSpacesArtifactError.invalidManifestSchema(manifest.schemaVersion) }
        guard manifest.appVersion == appVersion else {
            throw RemoteSpacesArtifactError.invalidManifestVersion(expected: appVersion, actual: manifest.appVersion)
        }
        return manifest
    }

    public static func verifyArtifactArchive(data: Data, artifact: RemoteSpacesArtifact) throws {
        let actual = try sha256Hex(data)
        guard actual.lowercased() == artifact.sha256.lowercased() else {
            throw RemoteSpacesArtifactError.checksumMismatch(expected: artifact.sha256.lowercased(), actual: actual.lowercased())
        }
    }

    public static func sha256Hex(_ data: Data) throws -> String {
        #if canImport(CryptoKit)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
            throw RemoteSpacesArtifactError.cryptographyUnavailable
        #endif
    }

    private static func verifySignature(message: Data, signature: Data, publicKey: String) throws {
        #if canImport(CryptoKit)
            let trimmed = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("REPLACE_WITH_"), let keyData = base64Data(trimmed), !keyData.isEmpty else {
                throw RemoteSpacesArtifactError.invalidPublicKey
            }
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
            guard key.isValidSignature(signature, for: message) else { throw RemoteSpacesArtifactError.invalidSignature }
        #else
            throw RemoteSpacesArtifactError.cryptographyUnavailable
        #endif
    }

    private static func base64Data(_ value: String) -> Data? {
        if let data = Data(base64Encoded: value) { return data }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 { base64.append(String(repeating: "=", count: 4 - remainder)) }
        return Data(base64Encoded: base64)
    }
}

public struct RemoteSpacesArtifactReleaseSource: Sendable {
    public let manifestURL: URL
    public let signatureURL: URL
    public let publicKey: String
    public let appVersion: String

    public init(manifestURL: URL, signatureURL: URL, publicKey: String, appVersion: String = AppVersion.current) {
        self.manifestURL = manifestURL
        self.signatureURL = signatureURL
        self.publicKey = publicKey
        self.appVersion = appVersion
    }

    public static func githubRelease(
        repository: String = "yogesh-dhande/spaces", appVersion: String = AppVersion.current, publicKey: String = AppVersion.remoteArtifactPublicKey
    ) throws -> RemoteSpacesArtifactReleaseSource {
        let releaseTag = "v\(appVersion)"
        let base = "https://github.com/\(repository)/releases/download/\(releaseTag)"
        guard let manifestURL = URL(string: "\(base)/spaces-remote-artifacts.json") else { throw RemoteSpacesArtifactError.invalidManifestURL(base) }
        guard let signatureURL = URL(string: "\(base)/spaces-remote-artifacts.json.sig") else {
            throw RemoteSpacesArtifactError.invalidManifestURL(base)
        }
        return RemoteSpacesArtifactReleaseSource(manifestURL: manifestURL, signatureURL: signatureURL, publicKey: publicKey, appVersion: appVersion)
    }

    public static func githubReleasePageURL(repository: String = "yogesh-dhande/spaces", appVersion: String = AppVersion.current) throws -> URL {
        let releaseTag = "v\(appVersion)"
        let page = "https://github.com/\(repository)/releases/tag/\(releaseTag)"
        guard let url = URL(string: page) else { throw RemoteSpacesArtifactError.invalidManifestURL(page) }
        return url
    }

    public func loadManifest() throws -> RemoteSpacesArtifactManifest {
        let manifestData = try Data(contentsOf: manifestURL)
        let signature = try Data(contentsOf: signatureURL)
        return try RemoteSpacesArtifactManifestVerifier.decodeVerifiedManifest(
            manifestData: manifestData, signature: signature, publicKey: publicKey, appVersion: appVersion)
    }
}
