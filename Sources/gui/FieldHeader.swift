import AppKit

@MainActor
func makeFieldHeader(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 11, weight: .semibold)
    label.textColor = .secondaryLabelColor
    return label
}
