import Foundation
import Testing

@testable import spacesui

@Suite struct MCPClientConfigurationTests {
    /// Reports an explicit set of paths as executable so resolution is deterministic.
    private final class StubFileManager: FileManager {
        let executablePaths: Set<String>
        init(executablePaths: Set<String>) {
            self.executablePaths = executablePaths
            super.init()
        }
        override func isExecutableFile(atPath path: String) -> Bool { executablePaths.contains(path) }
    }

    @Test func prefersHelperPathWhenPresent() {
        let resolved = MCPClientConfiguration.resolvedCLIPath(
            fileManager: StubFileManager(executablePaths: ["/Users/test/.spaces/bin/spaces", "/usr/local/bin/spaces"]),
            bundleResourceCLIPath: "/Applications/Spaces.app/Contents/Resources/spaces",
            homeDirectoryPath: "/Users/test")
        #expect(resolved == "/Users/test/.spaces/bin/spaces")
    }

    @Test func fallsBackToBundleThenSystemPath() {
        let bundlePath = "/Applications/Spaces.app/Contents/Resources/spaces"
        let bundleResolved = MCPClientConfiguration.resolvedCLIPath(
            fileManager: StubFileManager(executablePaths: [bundlePath, "/usr/local/bin/spaces"]),
            bundleResourceCLIPath: bundlePath,
            homeDirectoryPath: "/Users/test")
        #expect(bundleResolved == bundlePath)

        let systemResolved = MCPClientConfiguration.resolvedCLIPath(
            fileManager: StubFileManager(executablePaths: ["/usr/local/bin/spaces"]),
            bundleResourceCLIPath: bundlePath,
            homeDirectoryPath: "/Users/test")
        #expect(systemResolved == "/usr/local/bin/spaces")
    }

    @Test func fallsBackToHelperPathWhenNothingInstalled() {
        let resolved = MCPClientConfiguration.resolvedCLIPath(
            fileManager: StubFileManager(executablePaths: []),
            bundleResourceCLIPath: nil,
            homeDirectoryPath: "/Users/test")
        #expect(resolved == "/Users/test/.spaces/bin/spaces")
    }

    @Test func buildsClaudeCodeAddCommand() {
        #expect(
            MCPClientConfiguration.claudeCodeAddCommand(cliPath: "/usr/local/bin/spaces")
                == "claude mcp add spaces -- /usr/local/bin/spaces mcp")
    }

    @Test func buildsCodexConfigTOML() {
        let expected = """
            [mcp_servers.spaces]
            command = "/usr/local/bin/spaces"
            args = ["mcp"]
            """
        #expect(MCPClientConfiguration.codexConfigTOML(cliPath: "/usr/local/bin/spaces") == expected)
    }

    @Test func clientSnippetsMatchConfiguration() {
        #expect(MCPClient.claudeCode.configSnippet(cliPath: "/usr/local/bin/spaces") == "claude mcp add spaces -- /usr/local/bin/spaces mcp")
        #expect(MCPClient.codexCLI.configSnippet(cliPath: "/usr/local/bin/spaces").hasPrefix("[mcp_servers.spaces]"))
    }
}
