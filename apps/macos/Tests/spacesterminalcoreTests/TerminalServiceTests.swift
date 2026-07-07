import Foundation
import XCTest

@testable import spacesterminalcore

#if os(macOS)
    import Darwin

    final class TerminalServiceTests: XCTestCase {
        // Regression: capturing output used to wait for exit before draining the pipe, which
        // deadlocks as soon as the child writes more than the kernel's 64KB pipe buffer
        // (observed live with `lsof -nP -U` during socket-owner lookups).
        func testCapturedStandardOutputDrainsOutputLargerThanThePipeBuffer() throws {
            let result = try XCTUnwrap(
                TerminalService.capturedStandardOutput(
                    executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "dd if=/dev/zero bs=1024 count=256 2>/dev/null | tr '\\0' 'x'"])
            )

            XCTAssertEqual(result.terminationStatus, 0)
            XCTAssertEqual(result.output.count, 256 * 1024)
        }

        func testResolveExecutableURLFindsServiceNextToInstalledCLI() throws {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let cli = root.appendingPathComponent("spaces", isDirectory: false)
            let service = root.appendingPathComponent("spacesd", isDirectory: false)
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
            let service = resources.appendingPathComponent("spacesd", isDirectory: false)
            try makeExecutableFile(at: appExecutable)
            try makeExecutableFile(at: service)

            let resolved = try TerminalService.resolveExecutableURL(environment: ["_": appExecutable.path])

            XCTAssertEqual(resolved.path, service.path)
        }

        func testResolveExecutableURLFindsServiceBesideBundledCLIResource() throws {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let resources = root.appendingPathComponent("Spaces.app/Contents/Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            let cli = resources.appendingPathComponent("spaces", isDirectory: false)
            let service = resources.appendingPathComponent("spacesd", isDirectory: false)
            try makeExecutableFile(at: cli)
            try makeExecutableFile(at: service)

            let resolved = try TerminalService.resolveExecutableURL(environment: ["_": cli.path])

            XCTAssertEqual(resolved.path, service.path)
        }

        func testResolveExecutableURLFindsServiceThroughHomeHelperSymlink() throws {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let resources = root.appendingPathComponent("Applications/Spaces.app/Contents/Resources", isDirectory: true)
            let helperBin = root.appendingPathComponent("Users/test/.spaces/bin", isDirectory: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: helperBin, withIntermediateDirectories: true)
            let cliTarget = resources.appendingPathComponent("spaces", isDirectory: false)
            let serviceTarget = resources.appendingPathComponent("spacesd", isDirectory: false)
            try makeExecutableFile(at: cliTarget)
            try makeExecutableFile(at: serviceTarget)
            let cliHelper = helperBin.appendingPathComponent("spaces", isDirectory: false)
            let serviceHelper = helperBin.appendingPathComponent("spacesd", isDirectory: false)
            try FileManager.default.createSymbolicLink(at: cliHelper, withDestinationURL: cliTarget)
            try FileManager.default.createSymbolicLink(at: serviceHelper, withDestinationURL: serviceTarget)

            let resolved = try TerminalService.resolveExecutableURL(environment: ["_": cliHelper.path])

            XCTAssertEqual(resolved.path, serviceHelper.path)
        }

        func testParseProcessIDsIgnoresWhitespaceAndInvalidLines() {
            XCTAssertEqual(TerminalService.parseProcessIDs("123\n\nnot-a-pid\n456 789\n"), [123, 456, 789])
        }

        func testParseSocketOwnerProcessIDsFiltersToMatchingSocketPath() {
            let socketPath = "/tmp/spaces-sockets-\(getuid())/service-current.sock"
            let output = """
                COMMAND     PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
                launchd       1 yogesh  12u  unix 0xffffffffffffffff      0t0      /tmp/spaces-sockets-\(getuid())/service-other.sock
                SpacesTer   222 yogesh  13u  unix 0xffffffffffffffff      0t0      \(socketPath)
                sleep       333 yogesh  14u  unix 0xffffffffffffffff      0t0      \(socketPath)
                broken      abc yogesh  15u  unix 0xffffffffffffffff      0t0      \(socketPath)
                """

            XCTAssertEqual(TerminalService.parseSocketOwnerProcessIDs(output, socketPath: socketPath), [222, 333])
        }

        func testCreateSessionRequestTimeoutUsesPositiveEnvironmentOverride() {
            XCTAssertEqual(TerminalService.createSessionRequestTimeout(environment: ["SPACESD_CREATE_TIMEOUT": "45"]), 45)
            XCTAssertEqual(TerminalService.createSessionRequestTimeout(environment: ["SPACESD_CREATE_TIMEOUT": "0"]), 30)
            XCTAssertEqual(TerminalService.createSessionRequestTimeout(environment: [:]), 30)
        }

        private func makeTemporaryDirectory() throws -> URL {
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(
                "spacesd tests \(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }

        private func makeExecutableFile(at url: URL) throws {
            try Data().write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }
#endif
