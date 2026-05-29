import Foundation
import XCTest

@testable import spacesterminalcore

#if os(macOS)
    final class TerminalServiceTests: XCTestCase {
        func testResolveExecutableURLFindsServiceNextToInstalledCLI() throws {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let cli = root.appendingPathComponent("spaces", isDirectory: false)
            let service = root.appendingPathComponent("SpacesTerminalService", isDirectory: false)
            try makeExecutableFile(at: cli)
            try makeExecutableFile(at: service)

            let resolved = try TerminalService.resolveExecutableURL(environment: ["_": cli.path])

            XCTAssertEqual(resolved.path, service.path)
        }

        func testResolveExecutableURLFindsServiceInAppBundleResources() throws {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let macOS = root.appendingPathComponent("Spaces.app/Contents/MacOS", isDirectory: true)
            let resources = root.appendingPathComponent("Spaces.app/Contents/Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            let appExecutable = macOS.appendingPathComponent("SpacesApp", isDirectory: false)
            let service = resources.appendingPathComponent("SpacesTerminalService", isDirectory: false)
            try makeExecutableFile(at: appExecutable)
            try makeExecutableFile(at: service)

            let resolved = try TerminalService.resolveExecutableURL(environment: ["_": appExecutable.path])

            XCTAssertEqual(resolved.path, service.path)
        }

        func testParseProcessIDsIgnoresWhitespaceAndInvalidLines() {
            XCTAssertEqual(TerminalService.parseProcessIDs("123\n\nnot-a-pid\n456 789\n"), [123, 456, 789])
        }

        func testCreateSessionRequestTimeoutUsesPositiveEnvironmentOverride() {
            XCTAssertEqual(TerminalService.createSessionRequestTimeout(environment: ["SPACES_TERMINAL_SERVICE_CREATE_TIMEOUT": "45"]), 45)
            XCTAssertEqual(TerminalService.createSessionRequestTimeout(environment: ["SPACES_TERMINAL_SERVICE_CREATE_TIMEOUT": "0"]), 30)
            XCTAssertEqual(TerminalService.createSessionRequestTimeout(environment: [:]), 30)
        }

        private func makeTemporaryDirectory() throws -> URL {
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(
                "spaces-terminal-service-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }

        private func makeExecutableFile(at url: URL) throws {
            try Data().write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }
#endif
