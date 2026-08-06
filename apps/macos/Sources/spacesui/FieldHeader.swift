import AppKit
import spacesterminalcore

@MainActor func makeFieldHeader(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = Typography.metadataTitle
    label.textColor = .secondaryLabelColor
    return label
}
