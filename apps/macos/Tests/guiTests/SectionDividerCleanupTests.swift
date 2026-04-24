import AppKit
import Testing
import streamctl

@testable import gui

@MainActor @Suite struct SectionDividerCleanupTests {
    @Test func processReloadDoesNotAccumulateDividers() {
        let section = ProcessesSection(processes: [
            ProcessTemplate(name: "api", command: "bun run dev"), ProcessTemplate(name: "worker", command: "bun run worker"),
        ])

        #expect(section.rowsStackArrangedSubviewCountForTesting == 3)

        section.reload(processes: [ProcessTemplate(name: "api", command: "bun run dev")])
        #expect(section.rowsStackArrangedSubviewCountForTesting == 1)

        section.reload(processes: [
            ProcessTemplate(name: "api", command: "bun run dev"), ProcessTemplate(name: "worker", command: "bun run worker"),
            ProcessTemplate(name: "jobs", command: "bun run jobs"),
        ])
        #expect(section.rowsStackArrangedSubviewCountForTesting == 5)
    }

    @Test func browserSessionReloadDoesNotAccumulateDividers() {
        let section = BrowserSessionsSection(sessions: [
            BrowserSession(name: "docs", url: "https://example.com/docs"), BrowserSession(name: "admin", url: "https://example.com/admin"),
        ])

        #expect(section.rowsStackArrangedSubviewCountForTesting == 3)

        section.reload(sessions: [BrowserSession(name: "docs", url: "https://example.com/docs")])
        #expect(section.rowsStackArrangedSubviewCountForTesting == 1)

        section.reload(sessions: [
            BrowserSession(name: "docs", url: "https://example.com/docs"), BrowserSession(name: "admin", url: "https://example.com/admin"),
            BrowserSession(name: "app", url: "https://example.com/app"),
        ])
        #expect(section.rowsStackArrangedSubviewCountForTesting == 5)
    }

    @Test func agentLauncherReloadDoesNotAccumulateDividers() {
        let section = AgentLaunchersSection(launchers: [
            AgentLauncher(name: "claude", command: "claude"), AgentLauncher(name: "codex", command: "codex"),
        ])

        #expect(section.rowsStackArrangedSubviewCountForTesting == 3)

        section.reload(launchers: [AgentLauncher(name: "claude", command: "claude")])
        #expect(section.rowsStackArrangedSubviewCountForTesting == 1)

        section.reload(launchers: [
            AgentLauncher(name: "claude", command: "claude"), AgentLauncher(name: "codex", command: "codex"),
            AgentLauncher(name: "reviewer", command: "reviewer"),
        ])
        #expect(section.rowsStackArrangedSubviewCountForTesting == 5)
    }

    @Test func portsReloadDoesNotAccumulateDividers() {
        let section = PortsSection(ports: [PortDefinition(name: "web"), PortDefinition(name: "api")])

        #expect(section.rowsStackArrangedSubviewCountForTesting == 3)

        section.reload(ports: [PortDefinition(name: "web")])
        #expect(section.rowsStackArrangedSubviewCountForTesting == 1)

        section.reload(ports: [PortDefinition(name: "web"), PortDefinition(name: "api"), PortDefinition(name: "jobs")])
        #expect(section.rowsStackArrangedSubviewCountForTesting == 5)
    }
}

extension ProcessesSection {
    fileprivate var rowsStackArrangedSubviewCountForTesting: Int { rowsStackForDividerTesting(in: view).arrangedSubviews.count }
}

extension BrowserSessionsSection {
    fileprivate var rowsStackArrangedSubviewCountForTesting: Int { rowsStackForDividerTesting(in: view).arrangedSubviews.count }
}

extension AgentLaunchersSection {
    fileprivate var rowsStackArrangedSubviewCountForTesting: Int { rowsStackForDividerTesting(in: view).arrangedSubviews.count }
}

extension PortsSection {
    fileprivate var rowsStackArrangedSubviewCountForTesting: Int { rowsStackForDividerTesting(in: view).arrangedSubviews.count }
}

@MainActor private func rowsStackForDividerTesting(in sectionView: NSView) -> NSStackView {
    let outer = sectionView.subviews.compactMap { $0 as? NSStackView }.first
    return outer?.arrangedSubviews.compactMap { $0 as? NSStackView }.last ?? NSStackView()
}
