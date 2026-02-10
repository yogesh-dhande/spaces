import XCTest
@testable import streamctl

final class ConfigStoreTests: XCTestCase {
    func testLoadCreatesDefaultConfigWhenMissing() throws {
        let dir = try makeTempDirectory()
        let path = dir.appendingPathComponent("config.yaml").path
        let store = ConfigStore(path: path)

        let config = try store.load()

        XCTAssertEqual(config.portRange.start, 20000)
        XCTAssertEqual(config.portRange.end, 30000)
        XCTAssertEqual(config.projects.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        let reloaded = try store.load()
        XCTAssertEqual(reloaded.portRange.start, 20000)
        XCTAssertEqual(reloaded.portRange.end, 30000)
        XCTAssertEqual(reloaded.projects.count, 0)
    }

    func testLoadResetsInvalidPortRange() throws {
        let dir = try makeTempDirectory()
        let path = dir.appendingPathComponent("config.yaml").path
        let yaml = """
        editor: none
        port_range:
          start: 30000
          end: 20000
        projects: []
        """
        try yaml.write(toFile: path, atomically: true, encoding: .utf8)
        let store = ConfigStore(path: path)

        let config = try store.load()

        XCTAssertEqual(config.portRange.start, 20000)
        XCTAssertEqual(config.portRange.end, 30000)
    }
}
