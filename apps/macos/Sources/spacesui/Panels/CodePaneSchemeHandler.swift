import Foundation
import WebKit

/// Serves the code pane's built web bundle to its `WKWebView` over a custom URL scheme instead of
/// `file://`. The bundle's `index.html` (see `CodePaneWeb/README.md`) loads its entry as
/// `<script type="module" crossorigin>` plus a `crossorigin` stylesheet; both are CORS-fetched, and a
/// `file://` origin is opaque, so WebKit blocks both outright and the page never runs its own JS (no
/// `ready` handshake ever arrives, and CSS never applies). Handing the page a stable, non-opaque origin
/// under this scheme instead lets the module script, stylesheet, and any Shiki dynamic-import chunks
/// load same-origin, exactly like a normal same-origin static site.
final class CodePaneSchemeHandler: NSObject, WKURLSchemeHandler {
    /// The scheme registered on the `WKWebViewConfiguration` in `CodePaneContentController.installWebView()`.
    static let scheme = "spaces-codepane"
    /// The bundle's entry point under this scheme. `CodePaneContentController` loads exactly this URL
    /// instead of the `file://` index URL `codePaneIndexURL()` resolves.
    static let entryURL = URL(string: "\(scheme)://codepane/index.html")!

    /// The resource directory every request is resolved against: `codePaneIndexURL()`'s parent, i.e.
    /// the built bundle's root (`index.html` plus the `assets/` directory). Passed in at init rather
    /// than re-resolved per request, since it never changes for the handler's lifetime.
    private let baseDirectory: URL

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        // The scheme's "host" is a fixed label (`codepane`), not a real host; only the path identifies
        // a file inside the bundle, mirroring how `index.html`'s own relative asset paths (`./assets/…`)
        // resolve once the base document's URL is this scheme.
        let relativePath = requestURL.path.isEmpty ? "index.html" : String(requestURL.path.dropFirst())
        let resolvedURL = baseDirectory.appendingPathComponent(relativePath).standardizedFileURL
        let standardizedBase = baseDirectory.standardizedFileURL
        // Guards path traversal (e.g. a crafted `../` request): the standardized resolved path must
        // stay inside the bundle directory, or the task fails rather than serving a file from outside it.
        guard resolvedURL.path == standardizedBase.path || resolvedURL.path.hasPrefix(standardizedBase.path + "/") else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        guard let data = try? Data(contentsOf: resolvedURL) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        guard let mimeType = Self.mimeType(forPathExtension: resolvedURL.pathExtension) else {
            // The built bundle (see `CodePaneWeb/README.md`) contains only .html, .js, and .css files
            // (verified against the checked-in `Resources/CodePane` tree); any other extension means
            // the bundle grew a new asset type that this handler must be taught about deliberately,
            // so this fails loudly rather than guessing a MIME type or serving one silently wrong.
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = URLResponse(url: requestURL, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil)
        // Everything the task needs is already read synchronously above, so the whole response is
        // delivered before `start()` returns: there is nothing left in flight for `webView(_:stop:)` to
        // cancel.
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    /// No-op: `webView(_:start:)` above always finishes (or fails) the task synchronously before
    /// returning, so by the time WebKit could ever call this, there is nothing outstanding left to stop.
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private static func mimeType(forPathExtension pathExtension: String) -> String? {
        switch pathExtension {
        case "html": return "text/html"
        case "js": return "text/javascript"
        case "css": return "text/css"
        default: return nil
        }
    }
}
