import AppKit

/// Settings → Coding Agents. The section is `CodingAgentsView`, which Settings shares with the launch
/// setup flow's coding-agents step; the controller only decides where it renders.
extension SettingsController {
    func renderCodingAgentsSection() {
        renderSettingsCards([codingAgents.makeCard()])
    }
}
