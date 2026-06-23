import Foundation
import Testing

@testable import spacesdeviceapi

@Suite struct DirectorySuggestionsTests {
    private func makeFixtureRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spaces-dir-suggest-\(UUID().uuidString)")
        let fileManager = FileManager.default
        for name in ["alpha", "alpine", "beta", ".hidden"] {
            try fileManager.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent("alpha-file.txt"))
        return root
    }

    @Test func emptyQueryReturnsNoSuggestions() {
        #expect(SpacesDeviceAPIServer.directorySuggestions(forPartialPath: "").isEmpty)
        #expect(SpacesDeviceAPIServer.directorySuggestions(forPartialPath: "   ").isEmpty)
    }

    @Test func trailingSlashListsAllChildDirectories() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let suggestions = SpacesDeviceAPIServer.directorySuggestions(forPartialPath: root.path + "/")
        let names = suggestions.map { ($0 as NSString).lastPathComponent }
        #expect(names == ["alpha", "alpine", "beta"])
    }

    @Test func prefixMatchesDirectoriesOnly() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let suggestions = SpacesDeviceAPIServer.directorySuggestions(forPartialPath: root.appendingPathComponent("alp").path)
        let names = suggestions.map { ($0 as NSString).lastPathComponent }
        #expect(names == ["alpha", "alpine"])
    }

    @Test func hiddenDirectoriesRequireDotPrefix() throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let withoutDot = SpacesDeviceAPIServer.directorySuggestions(forPartialPath: root.path + "/")
        #expect(!withoutDot.contains { ($0 as NSString).lastPathComponent == ".hidden" })

        let withDot = SpacesDeviceAPIServer.directorySuggestions(forPartialPath: root.appendingPathComponent(".hid").path)
        #expect(withDot.map { ($0 as NSString).lastPathComponent } == [".hidden"])
    }

    @Test func tildePrefixIsPreservedInSuggestions() {
        let suggestions = SpacesDeviceAPIServer.directorySuggestions(forPartialPath: "~/")
        #expect(suggestions.allSatisfy { $0.hasPrefix("~/") })
    }
}
