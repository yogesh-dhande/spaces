import Foundation
import SwiftUI

/// Markdown artifact viewer with a Rendered / Raw toggle. Rendered mode builds a self-contained HTML
/// document (markdown-it + inlined CSS) and shows it in the isolated `TerminalWebArtifactView`; Raw mode
/// reuses the plain-text viewer. The segmented toggle lives in the sheet's navigation-bar principal slot.
struct TerminalMarkdownArtifactView: View {
    let url: URL

    @State private var mode: Mode = .rendered
    /// The built rendered document, or `nil` while loading or after a read failure. Loaded once in `.task`
    /// so switching modes doesn't re-read the file.
    @State private var renderedDocument: String?
    @State private var didFailToLoad = false

    enum Mode: Hashable {
        case rendered
        case raw
    }

    var body: some View {
        Group {
            switch mode {
            case .rendered:
                if let renderedDocument {
                    TerminalWebArtifactView(load: .htmlString(renderedDocument))
                } else if didFailToLoad {
                    TerminalArtifactFailureView(message: "This Markdown file couldn't be read.") {
                        loadDocument()
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(uiColor: .systemBackground))
                }
            case .raw:
                TerminalTextArtifactView(url: url)
            }
        }
        .task { loadDocument() }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Display", selection: $mode) {
                    Text("Rendered").tag(Mode.rendered)
                    Text("Raw").tag(Mode.raw)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .accessibilityIdentifier("terminal.markdown.modePicker")
            }
        }
    }

    private func loadDocument() {
        didFailToLoad = false
        if let document = TerminalMarkdownDocument.make(fromFileAt: url) {
            renderedDocument = document
        } else {
            renderedDocument = nil
            didFailToLoad = true
        }
    }
}

/// Pure builder for the rendered-Markdown HTML document, isolated from SwiftUI/UIKit so the shell and its
/// escaping are unit-testable. The web view loads with `baseURL: nil` and a non-persistent store, so it
/// cannot fetch bundle files — the markdown-it JS and CSS are read from the app bundle and inlined here.
enum TerminalMarkdownDocument {
    /// Reads the Markdown file lossily and builds the rendered document, or returns `nil` if the file
    /// can't be read (the caller shows a failure state).
    static func make(fromFileAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let source = TerminalTextArtifact.lossyString(from: data)
        return makeHTML(markdownSource: source, markdownItJS: bundledMarkdownItJS(), css: bundledCSS())
    }

    /// Builds the full HTML document around `markdownSource`, inlining `markdownItJS` and `css`. The source
    /// is embedded as a JS string literal via `javaScriptStringLiteral` so no markdown content can break
    /// out of the `<script>` context. `markdownit({ html: false })` keeps any raw HTML in agent-authored
    /// Markdown inert (rendered as text, not injected as markup), which is the safe default for content
    /// that originates from a terminal session.
    static func makeHTML(markdownSource: String, markdownItJS: String, css: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <style>
        \(css)
        </style>
        </head>
        <body>
        <div id="content" class="markdown-body"></div>
        <script>
        \(markdownItJS)
        </script>
        <script>
        (function () {
          var src = \(javaScriptStringLiteral(for: markdownSource));
          try {
            var md = window.markdownit({ html: false, linkify: true });
            document.getElementById("content").innerHTML = md.render(src);
          } catch (e) {
            document.getElementById("content").textContent = src;
          }
        })();
        </script>
        </body>
        </html>
        """
    }

    /// Encodes `source` as a JS string literal safe to embed inside a `<script>` element. JSON encoding
    /// handles quotes/backslashes/control characters; the additional `<`, `>`, `&`, and line/paragraph
    /// separator escapes guarantee the result can never contain a literal `</script>` (or `<!--`) that
    /// would prematurely close the script context or be invalid as a JS string.
    static func javaScriptStringLiteral(for source: String) -> String {
        guard let data = try? JSONEncoder().encode(source),
            let json = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }
        return json
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    private static func bundledMarkdownItJS() -> String {
        bundleResourceString(forResource: "markdown-it.min", withExtension: "js")
    }

    private static func bundledCSS() -> String {
        bundleResourceString(forResource: "terminal-markdown", withExtension: "css")
    }

    private static func bundleResourceString(forResource name: String, withExtension ext: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
            let contents = try? String(contentsOf: url, encoding: .utf8)
        else {
            return ""
        }
        return contents
    }
}
