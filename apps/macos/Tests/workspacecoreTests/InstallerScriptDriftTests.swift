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

    func testInstallerTargetsLatestReleaseAndAcceptsNoVersionArgument() throws {
        let script = try String(contentsOf: Self.installerScriptURL, encoding: .utf8)
        // The evergreen one-liner (`curl ... | bash`) installs the latest release, so the script must
        // resolve the artifact from the latest-release download URL and must not require a version
        // argument (no mandatory-arg usage die).
        XCTAssertTrue(script.contains("releases/latest/download"))
        XCTAssertFalse(script.contains("usage: spaces-install-linux.sh <version>"))
    }

    func testWebPrebuildPublishesInstallerAsInstallScript() throws {
        let package = try String(contentsOf: Self.webPackageURL, encoding: .utf8)
        // The install script is served at usespaces.dev/install.sh via the web build's prebuild copy;
        // guard that publish mechanism against drift.
        XCTAssertTrue(package.contains("\"prebuild\""))
        XCTAssertTrue(package.contains("spaces-install-linux.sh"))
        XCTAssertTrue(package.contains("public/install.sh"))
    }

    private static var repoRootURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()  // workspacecoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // macos
            .deletingLastPathComponent()  // apps
            .deletingLastPathComponent()  // repo root
    }

    private static var installerScriptURL: URL { repoRootURL.appendingPathComponent("scripts/spaces-install-linux.sh") }

    private static var webPackageURL: URL { repoRootURL.appendingPathComponent("apps/web/package.json") }
}
