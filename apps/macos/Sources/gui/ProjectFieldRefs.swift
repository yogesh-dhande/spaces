import AppKit

struct ProjectFieldRefs {
    let projectID: String
    let setupView: NSTextView
    let stopView: NSTextView
    let portEditor: PortEditor
    let processEditor: ProcessEditor
    let browserSessionEditor: BrowserSessionEditor
    let agentLauncherEditor: AgentLauncherEditor
}
