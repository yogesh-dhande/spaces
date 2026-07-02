import Foundation
import XCTest

@testable import spacesterminalcore

#if os(macOS)
    final class SpacesBinaryLayoutTests: XCTestCase {
        func testMacPathPolicyResolvesInstalledBinaryPaths() {
            let app = URL(fileURLWithPath: "/Applications/Spaces.app", isDirectory: true)
            let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)

            XCTAssertEqual(SpacesBinaryLayout.appResourceURL(for: .spaces, appBundleURL: app).path, "/Applications/Spaces.app/Contents/Resources/spaces")
            XCTAssertEqual(SpacesBinaryLayout.appResourceURL(for: .spacesd, appBundleURL: app).path, "/Applications/Spaces.app/Contents/Resources/spacesd")
            XCTAssertEqual(SpacesBinaryLayout.appResourceURL(for: .spacesCaddy, appBundleURL: app).path, "/Applications/Spaces.app/Contents/Resources/caddy")
            XCTAssertEqual(SpacesBinaryLayout.systemLinkURL(for: .spaces).path, "/usr/local/bin/spaces")
            XCTAssertEqual(SpacesBinaryLayout.systemLinkURL(for: .spacesd).path, "/usr/local/bin/spacesd")
            XCTAssertEqual(SpacesBinaryLayout.systemLinkURL(for: .spacesCaddy).path, "/usr/local/bin/spaces-caddy")
            XCTAssertEqual(SpacesBinaryLayout.userHelperLinkURL(for: .spaces, homeDirectoryURL: home)?.path, "/Users/test/.spaces/bin/spaces")
            XCTAssertEqual(SpacesBinaryLayout.userHelperLinkURL(for: .spacesd, homeDirectoryURL: home)?.path, "/Users/test/.spaces/bin/spacesd")
            XCTAssertNil(SpacesBinaryLayout.userHelperLinkURL(for: .spacesCaddy, homeDirectoryURL: home))
            XCTAssertEqual(
                SpacesBinaryLayout.launchAgentURL(homeDirectoryURL: home).path,
                "/Users/test/Library/LaunchAgents/dev.usespaces.spacesd.plist")
        }

        func testRepairReplacesStaleCopiesWithSymlinksAndUpdatesLaunchAgentPath() throws {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let app = root.appendingPathComponent("Applications/Spaces.app", isDirectory: true)
            let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
            let systemBin = root.appendingPathComponent("usr/local/bin", isDirectory: true)
            let home = root.appendingPathComponent("Users/test", isDirectory: true)
            let helperBin = home.appendingPathComponent(".spaces/bin", isDirectory: true)
            let launchAgent = SpacesBinaryLayout.launchAgentURL(homeDirectoryURL: home)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: systemBin, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: helperBin, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: launchAgent.deletingLastPathComponent(), withIntermediateDirectories: true)

            for binary in SpacesOwnedBinary.allCases {
                try makeExecutableFile(at: SpacesBinaryLayout.appResourceURL(for: binary, appBundleURL: app))
                try makeExecutableFile(at: SpacesBinaryLayout.systemLinkURL(for: binary, systemBinDirectoryURL: systemBin))
            }
            try makeExecutableFile(at: SpacesBinaryLayout.userHelperLinkURL(for: .spaces, homeDirectoryURL: home)!)
            try makeExecutableFile(at: SpacesBinaryLayout.userHelperLinkURL(for: .spacesd, homeDirectoryURL: home)!)
            try Data(
                """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                  <key>Label</key>
                  <string>dev.usespaces.spacesd</string>
                  <key>ProgramArguments</key>
                  <array>
                    <string>/usr/local/bin/spacesd</string>
                  </array>
                </dict>
                </plist>
                """.utf8
            ).write(to: launchAgent)

            let result = SpacesMacInstallationRepair.repairCurrentAppInstallation(
                appBundleURL: app, systemBinDirectoryURL: systemBin, homeDirectoryURL: home, requireInstalledBundle: false)

            XCTAssertTrue(result.failedPaths.isEmpty)
            XCTAssertTrue(result.repairedPaths.contains(launchAgent.path))
            try assertSymlink(SpacesBinaryLayout.systemLinkURL(for: .spaces, systemBinDirectoryURL: systemBin), pointsTo: resources.appendingPathComponent("spaces"))
            try assertSymlink(
                SpacesBinaryLayout.systemLinkURL(for: .spacesd, systemBinDirectoryURL: systemBin),
                pointsTo: resources.appendingPathComponent("spacesd"))
            try assertSymlink(
                SpacesBinaryLayout.systemLinkURL(for: .spacesCaddy, systemBinDirectoryURL: systemBin),
                pointsTo: resources.appendingPathComponent("caddy"))
            try assertSymlink(
                SpacesBinaryLayout.userHelperLinkURL(for: .spaces, homeDirectoryURL: home)!,
                pointsTo: resources.appendingPathComponent("spaces"))
            try assertSymlink(
                SpacesBinaryLayout.userHelperLinkURL(for: .spacesd, homeDirectoryURL: home)!,
                pointsTo: resources.appendingPathComponent("spacesd"))

            let data = try Data(contentsOf: launchAgent)
            XCTAssertEqual(
                SpacesMacInstallationRepair.launchAgentProgramArguments(from: data),
                [SpacesBinaryLayout.userHelperLinkURL(for: .spacesd, homeDirectoryURL: home)!.path])
        }

        func testRepairSkipsNonAppBundleLaunches() throws {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let result = SpacesMacInstallationRepair.repairCurrentAppInstallation(
                appBundleURL: root.appendingPathComponent("SpacesApp", isDirectory: false), systemBinDirectoryURL: root, homeDirectoryURL: root,
                requireInstalledBundle: false)

            XCTAssertFalse(result.repairedAnything)
            XCTAssertFalse(result.failedAnything)
        }

        private func makeTemporaryDirectory() throws -> URL {
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(
                "spaces-layout-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }

        private func makeExecutableFile(at url: URL) throws {
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        private func assertSymlink(_ link: URL, pointsTo target: URL, file: StaticString = #filePath, line: UInt = #line) throws {
            let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
            XCTAssertEqual(destination, target.path, file: file, line: line)
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: link.path), file: file, line: line)
        }
    }
#endif
