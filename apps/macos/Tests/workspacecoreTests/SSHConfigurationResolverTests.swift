import XCTest

@testable import workspacecore

final class SSHConfigurationResolverTests: XCTestCase {
    func testParseOpenSSHConfigurationExtractsHostnameUserAndPort() {
        let resolved = SSHConfigurationResolver.parseOpenSSHConfiguration(
            """
            host builder
            user runner
            hostname 10.0.0.42
            port 2222
            compression no
            """)

        XCTAssertEqual(resolved.hostname, "10.0.0.42")
        XCTAssertEqual(resolved.user, "runner")
        XCTAssertEqual(resolved.port, 2222)
    }

    func testParseOpenSSHConfigurationIgnoresMissingHostname() {
        let resolved = SSHConfigurationResolver.parseOpenSSHConfiguration(
            """
            user runner
            hostname none
            """)

        XCTAssertNil(resolved.hostname)
        XCTAssertEqual(resolved.resolvedHostname(fallback: "builder.local"), "builder.local")
    }
}
