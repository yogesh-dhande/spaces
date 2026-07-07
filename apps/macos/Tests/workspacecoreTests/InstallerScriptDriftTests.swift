import Foundation
import XCTest

@testable import workspacecore

/// Guards the Linux daemon installer against drifting away from the app's
/// canonical remote-artifact signing key. `scripts/spaces-install-linux.sh`
/// runs on a bare Linux host with no access to this repository, so it embeds
/// the Ed25519 public key literally. If the key is rotated in
/// `apps/macos/AppVersion.plist` (regenerating ``AppVersion``), the installer
/// must be updated in the same change or it will reject every signed manifest.
final class InstallerScriptDriftTests: XCTestCase {
    func testInstallerEmbedsCurrentRemoteArtifactPublicKey() throws {
        let script = try String(contentsOf: Self.installerScriptURL, encoding: .utf8)
        XCTAssertTrue(
            script.contains("REMOTE_ARTIFACT_PUBLIC_KEY=\"\(AppVersion.remoteArtifactPublicKey)\""),
            """
            scripts/spaces-install-linux.sh must embed AppVersion.remoteArtifactPublicKey \
            (\(AppVersion.remoteArtifactPublicKey)). Update the installer when rotating the \
            remote-artifact signing key.
            """)
    }

    private static var installerScriptURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()  // workspacecoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // macos
            .deletingLastPathComponent()  // apps
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("scripts/spaces-install-linux.sh")
    }
}
