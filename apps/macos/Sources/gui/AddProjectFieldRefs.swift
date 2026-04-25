import AppKit

struct AddProjectFieldRefs {
    let sourcePopup: NSPopUpButton
    let localSourceSection: NSStackView
    let cloneSourceSection: NSStackView
    let dirField: NSTextField
    let repoURLField: NSTextField
    let browseButton: NSButton
    let progressiveInputViews: [NSView]
    let createButton: NSButton
    let setupScriptSection: SetupScriptSection
    let stopScriptSection: StopScriptSection
    let portsSection: PortsSection
    let processesSection: ProcessesSection
    let browserSessionsSection: BrowserSessionsSection
    let agentLaunchersSection: AgentLaunchersSection
}
