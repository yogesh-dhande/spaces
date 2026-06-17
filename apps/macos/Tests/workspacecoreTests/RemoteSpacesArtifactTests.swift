import Foundation
import XCTest

@testable import workspacecore

#if canImport(CryptoKit)
    import CryptoKit
#endif

final class RemoteSpacesArtifactTests: XCTestCase {
    func testSelectsMacOSUniversalArtifactForMacOS14() throws {
        let artifact = try RemoteSpacesArtifactSelector.select(
            manifest: Self.manifest, for: RemoteSpacesPlatformProbe(operatingSystem: "Darwin", architecture: "arm64", macOSVersion: "14.5"),
            appVersion: "1.2.3")

        XCTAssertEqual(artifact.id, "spacesd-macos-universal")
    }

    func testSelectsUbuntuArtifactsByArchitecture() throws {
        let x86 = try RemoteSpacesArtifactSelector.select(
            manifest: Self.manifest,
            for: RemoteSpacesPlatformProbe(operatingSystem: "Linux", architecture: "x86_64", linuxID: "ubuntu", linuxVersionID: "24.04"),
            appVersion: "1.2.3")
        let arm = try RemoteSpacesArtifactSelector.select(
            manifest: Self.manifest,
            for: RemoteSpacesPlatformProbe(operatingSystem: "Linux", architecture: "aarch64", linuxID: "ubuntu", linuxVersionID: "24.04"),
            appVersion: "1.2.3")

        XCTAssertEqual(x86.id, "spacesd-ubuntu-24.04-x86_64")
        XCTAssertEqual(arm.id, "spacesd-ubuntu-24.04-arm64")
    }

    func testRejectsUnsupportedPlatform() {
        XCTAssertThrowsError(
            try RemoteSpacesArtifactSelector.artifactID(
                for: RemoteSpacesPlatformProbe(operatingSystem: "Linux", architecture: "x86_64", linuxID: "debian", linuxVersionID: "12"))
        ) { error in
            guard case RemoteSpacesArtifactError.unsupportedPlatform = error else {
                XCTFail("Expected unsupported platform, got \(error)")
                return
            }
        }
    }

    func testRejectsChecksumMismatch() throws {
        var artifact = Self.manifest.artifacts[0]
        artifact = RemoteSpacesArtifact(
            id: artifact.id, version: artifact.version, platform: artifact.platform, architecture: artifact.architecture,
            archiveName: artifact.archiveName, url: artifact.url, sha256: "0000000000000000000000000000000000000000000000000000000000000000")

        XCTAssertThrowsError(try RemoteSpacesArtifactManifestVerifier.verifyArtifactArchive(data: Data("archive".utf8), artifact: artifact)) {
            error in
            guard case RemoteSpacesArtifactError.checksumMismatch = error else {
                XCTFail("Expected checksum mismatch, got \(error)")
                return
            }
        }
    }

    func testBuildsGitHubReleasePageURL() throws {
        let url = try RemoteSpacesArtifactReleaseSource.githubReleasePageURL(repository: "example/spaces", appVersion: "1.2.3")

        XCTAssertEqual(url.absoluteString, "https://github.com/example/spaces/releases/tag/v1.2.3")
    }

    #if canImport(CryptoKit)
        func testVerifiesSignedManifest() throws {
            let manifestData = try JSONEncoder().encode(Self.manifest)
            let privateKey = Curve25519.Signing.PrivateKey()
            let signature = try privateKey.signature(for: manifestData)
            let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()

            let decoded = try RemoteSpacesArtifactManifestVerifier.decodeVerifiedManifest(
                manifestData: manifestData, signature: signature, publicKey: publicKey, appVersion: "1.2.3")

            XCTAssertEqual(decoded, Self.manifest)
        }

        func testRejectsInvalidManifestSignature() throws {
            let manifestData = try JSONEncoder().encode(Self.manifest)
            let privateKey = Curve25519.Signing.PrivateKey()
            let otherKey = Curve25519.Signing.PrivateKey()
            let signature = try privateKey.signature(for: manifestData)

            XCTAssertThrowsError(
                try RemoteSpacesArtifactManifestVerifier.decodeVerifiedManifest(
                    manifestData: manifestData, signature: signature, publicKey: otherKey.publicKey.rawRepresentation.base64EncodedString(),
                    appVersion: "1.2.3")
            ) { error in XCTAssertEqual(error as? RemoteSpacesArtifactError, .invalidSignature) }
        }
    #endif

    private static let manifest = RemoteSpacesArtifactManifest(
        appVersion: "1.2.3", releaseTag: "v1.2.3",
        artifacts: [
            RemoteSpacesArtifact(
                id: "spacesd-macos-universal", version: "1.2.3", platform: "macos", architecture: "universal",
                archiveName: "spacesd-macos-universal.tar.gz", url: "https://example.com/spacesd-macos-universal.tar.gz",
                sha256: try! RemoteSpacesArtifactManifestVerifier.sha256Hex(Data("archive".utf8))),
            RemoteSpacesArtifact(
                id: "spacesd-ubuntu-24.04-x86_64", version: "1.2.3", platform: "ubuntu-24.04", architecture: "x86_64",
                archiveName: "spacesd-ubuntu-24.04-x86_64.tar.gz", url: "https://example.com/spacesd-ubuntu-24.04-x86_64.tar.gz",
                sha256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
            RemoteSpacesArtifact(
                id: "spacesd-ubuntu-24.04-arm64", version: "1.2.3", platform: "ubuntu-24.04", architecture: "arm64",
                archiveName: "spacesd-ubuntu-24.04-arm64.tar.gz", url: "https://example.com/spacesd-ubuntu-24.04-arm64.tar.gz",
                sha256: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
        ])
}
