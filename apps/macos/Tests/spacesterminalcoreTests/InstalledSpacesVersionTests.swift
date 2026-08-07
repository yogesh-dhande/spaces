import Foundation
import XCTest

@testable import spacesterminalcore

/// The daemon learns what is installed on its own device by reading it off disk. These exercise the
/// real on-disk layouts each platform installs into, because the whole point of the value is to notice
/// a build that landed after the daemon started.
final class InstalledSpacesVersionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(
            "installed-version-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    #if os(macOS)
        /// A Sparkle update replaces Spaces.app in place, so the daemon still running out of that bundle
        /// reads the *new* version from the bundle it lives in.
        func testReadsVersionFromTheAppBundleContainingTheDaemon() throws {
            let bundle = try makeAppBundle(version: "0.2.0")
            let daemon = bundle.appendingPathComponent("Contents/Resources/spacesd", isDirectory: false)

            XCTAssertEqual(InstalledSpacesVersion.installedAppBundleVersion(executableURL: daemon), "0.2.0")
        }

        /// launchd execs `~/.spaces/bin/spacesd`, a symlink into the bundle, so the version can only be
        /// found by resolving the symlink first.
        func testResolvesSymlinkedDaemonPathBackIntoTheBundle() throws {
            let bundle = try makeAppBundle(version: "0.2.0")
            let daemon = bundle.appendingPathComponent("Contents/Resources/spacesd", isDirectory: false)
            let link = root.appendingPathComponent("spacesd-link", isDirectory: false)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: daemon)

            XCTAssertEqual(InstalledSpacesVersion.installedAppBundleVersion(executableURL: link), "0.2.0")
        }

        /// A development daemon launched from `.build/debug` sits in no app bundle, so there is no
        /// installed build to restart onto.
        func testReportsNoInstalledVersionForADaemonOutsideAnAppBundle() throws {
            let daemon = root.appendingPathComponent(".build/debug/spacesd", isDirectory: false)
            try FileManager.default.createDirectory(at: daemon.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: daemon)

            XCTAssertNil(InstalledSpacesVersion.installedAppBundleVersion(executableURL: daemon))
        }

        private func makeAppBundle(version: String) throws -> URL {
            let bundle = root.appendingPathComponent("Spaces.app", isDirectory: true)
            try FileManager.default.createDirectory(
                at: bundle.appendingPathComponent("Contents/Resources", isDirectory: true), withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleShortVersionString": version]
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: bundle.appendingPathComponent("Contents/Info.plist", isDirectory: false))
            try Data().write(to: bundle.appendingPathComponent("Contents/Resources/spacesd", isDirectory: false))
            return bundle
        }
    #else
        /// The installer repoints the release tree's `current` at the new release while the old daemon
        /// keeps running from its own release directory, so the manifest behind `current` — found from
        /// the running executable's own release tree, never a fixed home path — names what is
        /// installed. A daemon serving a development profile reads that profile's tree, so another
        /// profile's installed build can never appear as this daemon's staged update.
        func testReadsInstalledVersionFromItsOwnReleaseTreeCurrentManifest() throws {
            let runningDaemon = try makeRelease(version: "0.1.0")
            _ = try makeRelease(version: "0.2.0", current: true)

            XCTAssertEqual(InstalledSpacesVersion.installedReleaseVersion(executableURL: runningDaemon), "0.2.0")
        }

        /// systemd execs the daemon through the `current` symlink; the version must resolve through it
        /// back into the release tree.
        func testResolvesSymlinkedDaemonPathBackIntoItsReleaseTree() throws {
            _ = try makeRelease(version: "0.2.0", current: true)
            let linked = root.appendingPathComponent("daemon/current/bin/spacesd-bin", isDirectory: false)

            XCTAssertEqual(InstalledSpacesVersion.installedReleaseVersion(executableURL: linked), "0.2.0")
        }

        /// A development daemon launched from `.build/debug` sits in no release tree, so there is no
        /// installed build to restart onto.
        func testReportsNoInstalledVersionForADaemonOutsideAReleaseTree() throws {
            let daemon = root.appendingPathComponent(".build/debug/spacesd-bin", isDirectory: false)
            try FileManager.default.createDirectory(at: daemon.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: daemon)

            XCTAssertNil(InstalledSpacesVersion.installedReleaseVersion(executableURL: daemon))
        }

        /// Creates `daemon/releases/<version>/` with its manifest and `bin/spacesd-bin`, returning the
        /// executable inside it; `current: true` also points `daemon/current` at the release.
        private func makeRelease(version: String, current: Bool = false) throws -> URL {
            let release = root.appendingPathComponent("daemon/releases/\(version)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: release.appendingPathComponent("bin", isDirectory: true), withIntermediateDirectories: true)
            let manifest = try JSONSerialization.data(withJSONObject: ["app_version": version])
            try manifest.write(to: release.appendingPathComponent("manifest.json", isDirectory: false))
            let daemon = release.appendingPathComponent("bin/spacesd-bin", isDirectory: false)
            try Data().write(to: daemon)
            guard current else { return daemon }
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("daemon/current", isDirectory: false), withDestinationURL: release)
            return daemon
        }
    #endif
}
