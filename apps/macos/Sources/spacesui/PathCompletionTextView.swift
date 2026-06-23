import AppKit

/// Field editor for path inputs whose completion replaces only the trailing path
/// segment (the text after the last `/`), so selecting a nested folder appends to
/// the path instead of overwriting earlier segments.
@MainActor final class PathCompletionTextView: NSTextView {
    override var rangeForUserCompletion: NSRange {
        let text = string as NSString
        let caret = selectedRange().location
        guard caret <= text.length else { return super.rangeForUserCompletion }
        let lastSlash = text.range(of: "/", options: .backwards, range: NSRange(location: 0, length: caret))
        let start = lastSlash.location == NSNotFound ? 0 : lastSlash.location + 1
        return NSRange(location: start, length: caret - start)
    }
}
