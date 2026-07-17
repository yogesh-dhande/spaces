import SwiftUI
import UIKit

/// Non-editable, selectable, monospaced viewer for plain-text terminal artifacts (and the raw mode of
/// the Markdown viewer). Backs onto `UITextView` rather than SwiftUI `Text` because a multi-MB log would
/// stall or blow up layout in `Text`; `UITextView` lays out lazily and stays scrollable and selectable.
struct TerminalTextArtifactView: View {
    let url: URL

    var body: some View {
        TerminalTextArtifactTextView(text: TerminalTextArtifact.displayText(fileURL: url)).background(Color(uiColor: .systemBackground))
            .ignoresSafeArea(edges: .bottom).accessibilityIdentifier("terminal.textArtifact")
    }
}

/// Pure text-loading helpers, isolated from UIKit rendering so truncation and decoding are unit-testable.
enum TerminalTextArtifact {
    /// Cap on the number of characters handed to the text view. A preview file is already capped at a few
    /// MB upstream, but a dense log can still be large enough that displaying every character hurts
    /// scrolling; past this the tail is dropped from the *display* only (the full file stays available via
    /// Share).
    static let displayCharacterLimit = 2_000_000
    static let truncationFooter = "\n\n— truncated for display (full file via Share) —"

    /// Reads the file and returns text ready to display: lossily decoded, then truncated for display.
    /// A read failure yields an empty string rather than throwing — the sheet only reaches here for a file
    /// it just downloaded, so a failure is degenerate and an empty viewer is an acceptable floor.
    static func displayText(fileURL: URL) -> String {
        guard let data = try? Data(contentsOf: fileURL) else { return "" }
        return truncatedForDisplay(lossyString(from: data))
    }

    /// Decodes bytes as UTF-8, substituting the replacement character for invalid sequences instead of
    /// throwing, so binary or mislabeled content still renders as (garbled but safe) text.
    static func lossyString(from data: Data) -> String { String(decoding: data, as: UTF8.self) }

    /// Passes text through unchanged when it is within the display cap; otherwise returns the leading
    /// `displayCharacterLimit` characters followed by a visible truncation footer.
    static func truncatedForDisplay(_ text: String) -> String {
        guard text.count > displayCharacterLimit else { return text }
        let cutoff = text.index(text.startIndex, offsetBy: displayCharacterLimit)
        return String(text[..<cutoff]) + truncationFooter
    }
}

private struct TerminalTextArtifactTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .systemBackground
        textView.textColor = .label
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        // Base size 13pt, scaled by Dynamic Type so the monospaced body still respects text-size settings.
        let baseFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: baseFont)
        textView.adjustsFontForContentSizeCategory = true
        textView.text = text
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) { if textView.text != text { textView.text = text } }
}
