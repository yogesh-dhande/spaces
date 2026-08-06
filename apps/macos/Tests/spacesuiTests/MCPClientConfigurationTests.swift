import Foundation
import Testing
import spacesterminalcore

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
            bundleResourceCLIPath: "/Applications/Spaces.app/Contents/Resources/spaces", homeDirectoryPath: "/Users/test")
        #expect(resolved == "/Users/test/.spaces/bin/spaces")
    }

    @Test func fallsBackToBundleThenSystemPath() {
        let bundlePath = "/Applications/Spaces.app/Contents/Resources/spaces"
        let bundleResolved = MCPClientConfiguration.resolvedCLIPath(
            fileManager: StubFileManager(executablePaths: [bundlePath, "/usr/local/bin/spaces"]), bundleResourceCLIPath: bundlePath,
            homeDirectoryPath: "/Users/test")
        #expect(bundleResolved == bundlePath)

        let systemResolved = MCPClientConfiguration.resolvedCLIPath(
            fileManager: StubFileManager(executablePaths: ["/usr/local/bin/spaces"]), bundleResourceCLIPath: bundlePath,
            homeDirectoryPath: "/Users/test")
        #expect(systemResolved == "/usr/local/bin/spaces")
    }

    @Test func fallsBackToHelperPathWhenNothingInstalled() {
        let resolved = MCPClientConfiguration.resolvedCLIPath(
            fileManager: StubFileManager(executablePaths: []), bundleResourceCLIPath: nil, homeDirectoryPath: "/Users/test")
        #expect(resolved == "/Users/test/.spaces/bin/spaces")
    }

    @Test func buildsClaudeCodeAddCommandUserScoped() {
        #expect(
            MCPClientConfiguration.claudeCodeAddCommand(cliPath: "/usr/local/bin/spaces")
                == "claude mcp add spaces -s user -- /usr/local/bin/spaces mcp")
    }

    @Test func buildsCodexConfigTOML() {
        let expected = """
            [mcp_servers.spaces]
            command = "/usr/local/bin/spaces"
            args = ["mcp"]
            """
        #expect(MCPClientConfiguration.codexConfigTOML(cliPath: "/usr/local/bin/spaces") == expected)
    }

    @Test func buildsOpencodeConfigJSON() throws {
        let snippet = MCPClientConfiguration.opencodeConfigJSON(cliPath: "/usr/local/bin/spaces")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(snippet.utf8)) as? [String: Any])
        let mcp = try #require(object["mcp"] as? [String: Any])
        let spaces = try #require(mcp["spaces"] as? [String: Any])
        #expect(spaces["type"] as? String == "local")
        #expect(spaces["command"] as? [String] == ["/usr/local/bin/spaces", "mcp"])
        #expect(spaces["enabled"] as? Bool == true)
    }

    @Test func clientSnippetsMatchConfiguration() {
        #expect(CodingAgent.allCases == [.claudeCode, .codex, .opencode])
        #expect(
            CodingAgent.claudeCode.mcpConfigSnippet(cliPath: "/usr/local/bin/spaces") == "claude mcp add spaces -s user -- /usr/local/bin/spaces mcp")
        #expect(CodingAgent.codex.mcpConfigSnippet(cliPath: "/usr/local/bin/spaces").hasPrefix("[mcp_servers.spaces]"))
        #expect(CodingAgent.opencode.mcpConfigSnippet(cliPath: "/usr/local/bin/spaces").contains("\"type\": \"local\""))
    }

    /// Every registered coding agent must yield a usable MCP client tab: a non-empty title, a
    /// non-empty setup hint, and a config snippet that actually embeds the resolved CLI path.
    @Test func everyCodingAgentYieldsAUsableMCPClientTab() {
        let cliPath = "/usr/local/bin/spaces"
        for agent in CodingAgent.allCases {
            #expect(!agent.mcpClientTitle.isEmpty)
            #expect(!agent.mcpConfigHint.isEmpty)
            #expect(agent.mcpConfigSnippet(cliPath: cliPath).contains(cliPath))
        }
    }
}
