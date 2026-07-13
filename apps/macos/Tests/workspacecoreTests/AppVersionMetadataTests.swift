import Foundation
import Testing

@testable import workspacecore

struct AppVersionMetadataTests {
    private let sourcePlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("AppVersion.plist")

    private let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/SpacesApp/Info.plist")

    private let iOSInfoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("ios/Info.plist")

    @Test func sharedSwiftVersionMatchesSourceMetadata() throws {
        let metadata = try readPlist(at: sourcePlist)

        #expect(AppVersion.short == metadata["CFBundleShortVersionString"] as? String)
        #expect(AppVersion.build == metadata["CFBundleVersion"] as? String)
        #expect(AppVersion.remoteArtifactPublicKey == metadata["SpacesRemoteArtifactPublicEd25519Key"] as? String)
    }

    @Test func appBundleMetadataMatchesSourceMetadata() throws {
        let source = try readPlist(at: sourcePlist)
        let bundle = try readPlist(at: infoPlist)

        #expect(bundle["CFBundleShortVersionString"] as? String == source["CFBundleShortVersionString"] as? String)
        #expect(bundle["CFBundleVersion"] as? String == source["CFBundleVersion"] as? String)
        #expect(bundle["SUFeedURL"] as? String == source["SUFeedURL"] as? String)
        #expect(bundle["SUPublicEDKey"] as? String == source["SUPublicEDKey"] as? String)
        // The bundle is generated wholesale from a template in scripts/sync-app-version.sh, so a key
        // missing from that template is silently dropped on the next sync. Without this one macOS
        // denies the app the Apple Events it needs to open and focus Chrome browser sessions.
        #expect(bundle["NSAppleEventsUsageDescription"] as? String != nil)
    }

    /// Spaces ships one version across its clients, so the iPhone bundle is generated from the same
    /// source as the Mac's by `scripts/sync-app-version.sh` rather than authored by hand.
    @Test func iOSBundleMetadataMatchesSourceMetadata() throws {
        let source = try readPlist(at: sourcePlist)
        let bundle = try readPlist(at: iOSInfoPlist)

        #expect(bundle["CFBundleShortVersionString"] as? String == source["CFBundleShortVersionString"] as? String)
        #expect(bundle["CFBundleVersion"] as? String == source["CFBundleVersion"] as? String)
    }

    private func readPlist(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }
}
