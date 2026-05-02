import Foundation
import Testing

@testable import workspacecore

struct AppVersionMetadataTests {
    private let sourcePlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("AppVersion.plist")

    private let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/SpacesApp/Info.plist")

    @Test func sharedSwiftVersionMatchesSourceMetadata() throws {
        let metadata = try readPlist(at: sourcePlist)

        #expect(AppVersion.short == metadata["CFBundleShortVersionString"] as? String)
        #expect(AppVersion.build == metadata["CFBundleVersion"] as? String)
    }

    @Test func appBundleMetadataMatchesSourceMetadata() throws {
        let source = try readPlist(at: sourcePlist)
        let bundle = try readPlist(at: infoPlist)

        #expect(bundle["CFBundleShortVersionString"] as? String == source["CFBundleShortVersionString"] as? String)
        #expect(bundle["CFBundleVersion"] as? String == source["CFBundleVersion"] as? String)
        #expect(bundle["SUFeedURL"] as? String == source["SUFeedURL"] as? String)
        #expect(bundle["SUPublicEDKey"] as? String == source["SUPublicEDKey"] as? String)
    }

    private func readPlist(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }
}
