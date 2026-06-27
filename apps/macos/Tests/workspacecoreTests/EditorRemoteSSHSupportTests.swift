import Foundation
import XCTest

@testable import workspacecore

final class EditorRemoteSSHSupportTests: XCTestCase {
    // Tests init fails for a bundle without VS Code-family product.json fields.
    func testInitFailsWhenProductFieldsMissing() throws {
        let (app, _) = try makeFakeEditor(includeProductFields: false)
        XCTAssertNil(EditorRemoteSSHSupport(appBundleURL: app))
    }

    // Tests the CLI executable path is derived from product.json applicationName.
    func testCLIExecutableURLResolvesFromApplicationName() throws {
        let (app, _) = try makeFakeEditor(applicationName: "devin-desktop")
        let support = try XCTUnwrap(EditorRemoteSSHSupport(appBundleURL: app))
        XCTAssertEqual(support.cliExecutableURL.lastPathComponent, "devin-desktop")
        XCTAssertTrue(support.cliExecutableURL.path.hasSuffix("Contents/Resources/app/bin/devin-desktop"))
    }

    // Tests a remote-SSH extension bundled with the editor (as the forks ship) is detected.
    func testDetectsBuiltInRemoteSSHExtension() throws {
        let (app, home) = try makeFakeEditor(builtInExtensions: ["windsurf-remote-openssh", "eamodio.gitlens"])
        let support = try XCTUnwrap(EditorRemoteSSHSupport(appBundleURL: app))
        XCTAssertTrue(support.hasRemoteSSHExtension(homeDirectory: home))
    }

    // Tests a user-installed remote-SSH extension (as stock VS Code needs) is detected.
    func testDetectsUserInstalledRemoteSSHExtension() throws {
        let (app, home) = try makeFakeEditor(dataFolderName: ".fakecode")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".fakecode/extensions/ms-vscode-remote.remote-ssh-0.124.0"), withIntermediateDirectories: true)
        let support = try XCTUnwrap(EditorRemoteSSHSupport(appBundleURL: app))
        XCTAssertTrue(support.hasRemoteSSHExtension(homeDirectory: home))
    }

    // Tests capability is reported missing when no extension name mentions both remote and ssh.
    func testReportsMissingWhenNoRemoteSSHExtension() throws {
        let (app, home) = try makeFakeEditor(builtInExtensions: ["eamodio.gitlens"])
        let support = try XCTUnwrap(EditorRemoteSSHSupport(appBundleURL: app))
        XCTAssertFalse(support.hasRemoteSSHExtension(homeDirectory: home))
    }

    /// Builds a fake editor `.app` with a `product.json` and optional built-in extensions,
    /// plus an empty home directory, for offline detection tests.
    private func makeFakeEditor(
        applicationName: String = "fakecode", dataFolderName: String = ".fakecode", builtInExtensions: [String] = [],
        includeProductFields: Bool = true
    ) throws -> (app: URL, home: URL) {
        let root = try makeTempDirectory()
        let home = root.appendingPathComponent("home")
        let app = root.appendingPathComponent("FakeCode.app")
        let resourcesApp = app.appendingPathComponent("Contents/Resources/app")
        try FileManager.default.createDirectory(at: resourcesApp.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourcesApp.appendingPathComponent("extensions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let product: [String: Any] = includeProductFields ? ["applicationName": applicationName, "dataFolderName": dataFolderName] : [:]
        try JSONSerialization.data(withJSONObject: product).write(to: resourcesApp.appendingPathComponent("product.json"))
        for ext in builtInExtensions {
            try FileManager.default.createDirectory(at: resourcesApp.appendingPathComponent("extensions/\(ext)"), withIntermediateDirectories: true)
        }
        return (app, home)
    }
}
