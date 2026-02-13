import AppKit

struct ProjectFieldRefs {
    let projectID: String
    let setupView: NSTextView
    let cleanupView: NSTextView
    let processEditor: ProcessEditor
    let browserView: NSTextView
    let statusEditor: StatusCheckEditor
}
