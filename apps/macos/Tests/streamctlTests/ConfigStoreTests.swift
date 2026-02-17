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
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        let reloaded = try store.load()
        XCTAssertEqual(reloaded.portRange.start, 20000)
        XCTAssertEqual(reloaded.portRange.end, 30000)
    }

    func testLoadResetsInvalidPortRange() throws {
        let dir = try makeTempDirectory()
        let path = dir.appendingPathComponent("config.yaml").path
        let yaml = """
            editor: none
            port_range:
              start: 30000
              end: 20000
            """
        try yaml.write(toFile: path, atomically: true, encoding: .utf8)
        let store = ConfigStore(path: path)

        let config = try store.load()

        XCTAssertEqual(config.portRange.start, 20000)
        XCTAssertEqual(config.portRange.end, 30000)
    }

    func testLoadIgnoresLegacyProjectsKey() throws {
        let dir = try makeTempDirectory()
        let path = dir.appendingPathComponent("config.yaml").path
        let yaml = """
            editor: none
            port_range:
              start: 20000
              end: 30000
            projects:
              - dir: /tmp/some-project
                setup_script: echo setup
            """
        try yaml.write(toFile: path, atomically: true, encoding: .utf8)
        let store = ConfigStore(path: path)

        // AppConfig no longer has projects; decoding should succeed without error
        let config = try store.load()
        XCTAssertEqual(config.portRange.start, 20000)
    }
}
