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
    let setupView: NSTextView
    let stopView: NSTextView
    let portEditor: PortEditor
    let processEditor: ProcessEditor
    let browserSessionEditor: BrowserSessionEditor
    let agentLauncherEditor: AgentLauncherEditor
}
