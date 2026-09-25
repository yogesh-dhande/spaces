import AppKit
import spacesterminalcore

/// Renders a coding agent's brief (markdown the agent writes) as the attributed text the brief column
/// shows read-only.
///
/// Parsing is Foundation's `AttributedString(markdown:)`; this type only maps each block's
/// `presentationIntent` onto the chrome type scale and theme colors, so the brief reads as part of the
/// app rather than as a web page. Blocks are joined by a single newline and separated by paragraph
/// spacing, never by blank lines. A task-list item keeps its literal `[ ]` / `[x]` text as written in
/// place of a bullet: Foundation has no task-list intent, and the literal box is what the agent wrote.
enum AgentBriefMarkdown {
    static func attributedString(from markdown: String) -> NSAttributedString {
        let parsed: AttributedString
        do { parsed = try AttributedString(markdown: markdown, options: .init(failurePolicy: .returnPartiallyParsedIfPossible)) } catch {
            // The parser accepts any text under this failure policy, so this is unreachable in practice.
            // The source is still the brief, so it is shown as written rather than as nothing.
            return NSAttributedString(
                string: markdown, attributes: [.font: Typography.body, .foregroundColor: Theme.text, .paragraphStyle: bodyParagraphStyle()])
        }
        let output = NSMutableAttributedString()
        var previous: Block?
        for block in blocks(in: parsed) {
            // The newline ending a paragraph belongs to that paragraph, so it takes the paragraph's own
            // style and never restyles the next block. It carries no link or strikethrough of its own.
            if output.length > 0 {
                var terminator = output.attributes(at: output.length - 1, effectiveRange: nil)
                terminator[.link] = nil
                terminator[.strikethroughStyle] = nil
                output.append(NSAttributedString(string: "\n", attributes: terminator))
            }
            output.append(render(block, after: previous))
            previous = block
        }
        return output
    }

    // MARK: - Blocks

    /// One rendered paragraph's worth of runs, keyed by the identity of the block that holds them.
    private struct Block {
        let key: Int
        let intent: PresentationIntent?
        var runs: [Run]

        var components: [PresentationIntent.IntentType] { intent?.components ?? [] }

        var headingLevel: Int? {
            for component in components { if case .header(let level) = component.kind { return level } }
            return nil
        }

        var isCodeBlock: Bool { components.contains { if case .codeBlock = $0.kind { true } else { false } } }

        var isQuote: Bool { components.contains { $0.kind == .blockQuote } }

        /// How many lists enclose this block (1 for a top-level list item).
        var listDepth: Int { components.filter { $0.kind == .unorderedList || $0.kind == .orderedList }.count }

        /// The innermost list item enclosing this block: its identity and ordinal.
        var listItem: (identity: Int, ordinal: Int)? {
            for component in components { if case .listItem(let ordinal) = component.kind { return (component.identity, ordinal) } }
            return nil
        }

        /// Whether the innermost list enclosing this block is ordered.
        var isInOrderedList: Bool {
            for component in components {
                if component.kind == .orderedList { return true }
                if component.kind == .unorderedList { return false }
            }
            return false
        }

        /// The outermost list's identity, which two blocks share when they belong to one list.
        var outermostListIdentity: Int? { components.last { $0.kind == .unorderedList || $0.kind == .orderedList }?.identity }

        var text: String { runs.map(\.text).joined() }
    }

    private struct Run {
        let text: String
        let inline: InlinePresentationIntent
        let link: URL?
        /// The table cell holding this run, so cells of one row can be told apart.
        let tableCellIdentity: Int?
    }

    /// Groups the parsed runs into blocks. A table row is one block whose cells are tab-separated, so a
    /// row reads across instead of stacking every cell on its own line.
    private static func blocks(in parsed: AttributedString) -> [Block] {
        var blocks: [Block] = []
        for run in parsed.runs {
            let intent = run.presentationIntent
            let components = intent?.components ?? []
            let rowIdentity = components.first {
                switch $0.kind {
                case .tableRow, .tableHeaderRow: true
                default: false
                }
            }?.identity
            let cellIdentity = components.first { if case .tableCell = $0.kind { true } else { false } }?.identity
            let key = rowIdentity ?? components.first?.identity ?? -1
            let piece = Run(
                text: String(parsed[run.range].characters), inline: run.inlinePresentationIntent ?? [], link: run.link,
                tableCellIdentity: cellIdentity)
            if let last = blocks.indices.last, blocks[last].key == key {
                blocks[last].runs.append(piece)
            } else {
                blocks.append(Block(key: key, intent: intent, runs: [piece]))
            }
        }
        return blocks.filter { !$0.text.isEmpty }
    }

    // MARK: - Rendering

    private static let listIndentStep: CGFloat = 16
    private static let bulletWidth: CGFloat = 14
    private static let orderedMarkerWidth: CGFloat = 20
    private static let quoteIndent: CGFloat = 10
    private static let codeIndent: CGFloat = 8

    private static func render(_ block: Block, after previous: Block?) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let baseFont = font(for: block)
        let color = block.isQuote ? Theme.muted : Theme.text
        let spacingBefore = paragraphSpacingBefore(block, after: previous)

        if block.isCodeBlock {
            let lines = block.text.split(separator: "\n", omittingEmptySubsequences: false)
            let trimmed = lines.last == "" ? lines.dropLast() : lines[...]
            for (index, line) in trimmed.enumerated() {
                let style = bodyParagraphStyle()
                style.firstLineHeadIndent = codeIndent
                style.headIndent = codeIndent
                style.paragraphSpacingBefore = index == 0 ? spacingBefore : 0
                let attributes: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: color, .paragraphStyle: style]
                if index > 0 { output.append(NSAttributedString(string: "\n", attributes: attributes)) }
                output.append(NSAttributedString(string: String(line), attributes: attributes))
            }
            return output
        }

        let style = bodyParagraphStyle()
        style.paragraphSpacingBefore = spacingBefore
        var leadingIndent: CGFloat = block.isQuote ? quoteIndent : 0
        var marker: String?
        if let item = block.listItem {
            leadingIndent += CGFloat(block.listDepth - 1) * listIndentStep
            let isFirstParagraphOfItem = previous?.listItem?.identity != item.identity
            let checkboxPrefix = ["[ ] ", "[x] ", "[X] "].first { block.text.hasPrefix($0) }
            if let checkboxPrefix {
                // The literal box leads the line; wrapped lines hang under the text after it.
                let boxWidth = (checkboxPrefix as NSString).size(withAttributes: [.font: baseFont]).width
                style.firstLineHeadIndent = leadingIndent
                style.headIndent = leadingIndent + boxWidth
            } else {
                let markerWidth = block.isInOrderedList ? orderedMarkerWidth : bulletWidth
                style.firstLineHeadIndent = leadingIndent
                style.headIndent = leadingIndent + markerWidth
                style.tabStops = [NSTextTab(textAlignment: .left, location: leadingIndent + markerWidth)]
                if isFirstParagraphOfItem {
                    marker = block.isInOrderedList ? "\(item.ordinal).\t" : "•\t"
                } else {
                    style.firstLineHeadIndent = leadingIndent + markerWidth
                }
            }
        } else {
            style.firstLineHeadIndent = leadingIndent
            style.headIndent = leadingIndent
        }

        let baseAttributes: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: color, .paragraphStyle: style]
        if let marker {
            var markerAttributes = baseAttributes
            markerAttributes[.foregroundColor] = Theme.muted
            output.append(NSAttributedString(string: marker, attributes: markerAttributes))
        }
        var previousCellIdentity: Int?
        for run in block.runs {
            if let cell = run.tableCellIdentity {
                if let previousCellIdentity, previousCellIdentity != cell {
                    output.append(NSAttributedString(string: "\t", attributes: baseAttributes))
                }
                previousCellIdentity = cell
            }
            var attributes = baseAttributes
            if run.inline.contains(.code) {
                attributes[.font] = Typography.monoBody
            } else if run.inline.contains(.stronglyEmphasized), block.headingLevel == nil {
                attributes[.font] = Typography.sectionTitle
            }
            if run.inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            // A hard line break stays inside its paragraph, so it does not pick up paragraph spacing.
            output.append(NSAttributedString(string: run.text.replacingOccurrences(of: "\n", with: "\u{2028}"), attributes: attributes))
        }
        return output
    }

    private static func font(for block: Block) -> NSFont {
        if let level = block.headingLevel { return level == 1 ? Typography.cardTitle : Typography.sectionTitle }
        if block.isCodeBlock { return Typography.monoBody }
        return Typography.body
    }

    /// Space above a block, from what it follows: nothing above the first, more above a heading than
    /// under one, and list items of one list kept close together.
    private static func paragraphSpacingBefore(_ block: Block, after previous: Block?) -> CGFloat {
        guard let previous else { return 0 }
        if block.headingLevel != nil { return 12 }
        if previous.headingLevel != nil { return 4 }
        if let list = block.outermostListIdentity, list == previous.outermostListIdentity { return 3 }
        return 8
    }

    private static func bodyParagraphStyle() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        return style
    }
}
