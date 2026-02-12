import AppKit

struct AddProjectFieldRefs {
    let sourcePopup: NSPopUpButton
    let localSourceSection: NSStackView
    let cloneSourceSection: NSStackView
    let dirField: NSTextField
    let repoURLField: NSTextField
    let browseButton: NSButton
    let setupView: NSTextView
    let cleanupView: NSTextView
    let processEditor: ProcessEditor
    let browserView: NSTextView
    let statusEditor: StatusCheckEditor
}
