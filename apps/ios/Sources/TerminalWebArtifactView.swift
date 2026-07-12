import SwiftUI
import UIKit
import WebKit

/// What a `TerminalWebArtifactView` should load. The three modes share one isolated web view: a local
/// HTML artifact file, an external web page, or a rendered HTML string (used by the Markdown viewer).
enum TerminalWebArtifactLoad: Equatable {
    /// A local HTML artifact file. Read access is scoped to the single file (see `load(on:)`).
    case fileURL(URL)
    /// An external web page (a resolved `.webPage` link that has no previewable artifact).
    case request(URL)
    /// A self-contained rendered HTML document string with no external references.
    case htmlString(String)

    /// Back/forward swipe navigation only makes sense for a real multi-page web session, not a single
    /// artifact file or a one-shot rendered document.
    var allowsBackForwardNavigation: Bool {
        if case .request = self { return true }
        return false
    }

    var allowsNetworkLoads: Bool {
        if case .request = self { return true }
        return false
    }
}

enum TerminalWebArtifactNetworkPolicy {
    static let contentRuleListIdentifier = "TerminalWebArtifactNoNetwork"
    static let networkBlockContentRuleListJSON = """
        [
          {
            "trigger": {
              "url-filter": "^http://.*"
            },
            "action": {
              "type": "block"
            }
          },
          {
            "trigger": {
              "url-filter": "^https://.*"
            },
            "action": {
              "type": "block"
            }
          },
          {
            "trigger": {
              "url-filter": "^ws://.*"
            },
            "action": {
              "type": "block"
            }
          },
          {
            "trigger": {
              "url-filter": "^wss://.*"
            },
            "action": {
              "type": "block"
            }
          }
        ]
        """

    static func shouldBlockNetworkLoad(for load: TerminalWebArtifactLoad, url: URL) -> Bool {
        shouldBlockNetworkLoad(networkLoadsAllowed: load.allowsNetworkLoads, url: url)
    }

    static func shouldBlockNetworkLoad(networkLoadsAllowed: Bool, url: URL) -> Bool {
        guard !networkLoadsAllowed else { return false }
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "ws" || scheme == "wss"
    }

    @MainActor
    static func makeNetworkBlockContentRuleList() async throws -> WKContentRuleList {
        guard let ruleList = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: contentRuleListIdentifier,
            encodedContentRuleList: networkBlockContentRuleListJSON
        ) else {
            throw NSError(
                domain: "TerminalWebArtifactNetworkPolicy",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't prepare the isolated preview."]
            )
        }
        return ruleList
    }
}

/// Isolated `WKWebView` host for HTML artifacts and external web pages. Unlike the browser-sessions
/// feature (which deliberately persists cookies/storage), this view must never leak or reuse browsing
/// state, so it uses a fresh non-persistent data store per presentation. Adds a thin progress bar while
/// loading and a compact failure state with Retry on navigation error.
struct TerminalWebArtifactView: View {
    let load: TerminalWebArtifactLoad

    @State private var model = TerminalWebArtifactViewModel()

    var body: some View {
        VStack(spacing: 0) {
            if model.isLoading {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                    .frame(height: 2)
                    .accessibilityIdentifier("terminal.webArtifact.progress")
            }

            ZStack {
                TerminalWebArtifactRepresentable(load: load, model: model)
                if let message = model.loadErrorMessage {
                    TerminalArtifactFailureView(message: message) { model.retry?() }
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .ignoresSafeArea(edges: .bottom)
        .accessibilityIdentifier("terminal.webArtifact")
    }
}

/// Compact failure card (icon + message + Retry) shared by the web view's navigation-error state and the
/// Markdown viewer's file-read-failure state.
struct TerminalArtifactFailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.orange)
            Text("Couldn't load this content")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.text)
            Text(message)
                .font(.footnote)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Button("Retry", action: retry)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("terminal.webArtifact.retry")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .accessibilityIdentifier("terminal.webArtifact.error")
    }
}

/// Navigation state for the artifact web view, kept in sync by the coordinator's KVO and delegate
/// callbacks so the SwiftUI wrapper never holds a `WKWebView` reference.
@MainActor
@Observable
final class TerminalWebArtifactViewModel {
    var isLoading = false
    var progress: Double = 0
    var loadErrorMessage: String?
    var retry: (() -> Void)?
}

private struct TerminalWebArtifactRepresentable: UIViewRepresentable {
    let load: TerminalWebArtifactLoad
    let model: TerminalWebArtifactViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Non-persistent, per-presentation store: artifact viewing must not share cookies/storage with the
        // browser-sessions feature or leak state between one preview and the next.
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = load.allowsBackForwardNavigation
        webView.navigationDelegate = context.coordinator
        context.coordinator.attach(to: webView, load: load)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(load, on: webView)
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        private let model: TerminalWebArtifactViewModel
        private var loadedDescription: String?
        private var activeLoadAllowsNetwork = false
        private var loadTask: Task<Void, Never>?
        private var observations: [NSKeyValueObservation] = []

        init(model: TerminalWebArtifactViewModel) {
            self.model = model
        }

        deinit {
            loadTask?.cancel()
        }

        func attach(to webView: WKWebView, load: TerminalWebArtifactLoad) {
            model.retry = { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.loadedDescription = nil
                self.perform(load, on: webView)
            }
            observe(webView)
            self.load(load, on: webView)
        }

        /// Loads only when the target changed, so SwiftUI re-renders don't reload the page. The
        /// `TerminalWebArtifactLoad` cases carry no stable identity, so identity is a cheap string key.
        func load(_ load: TerminalWebArtifactLoad, on webView: WKWebView) {
            let description = Self.identity(for: load)
            guard loadedDescription != description else { return }
            loadedDescription = description
            perform(load, on: webView)
        }

        private func perform(_ load: TerminalWebArtifactLoad, on webView: WKWebView) {
            let description = Self.identity(for: load)
            activeLoadAllowsNetwork = load.allowsNetworkLoads
            loadTask?.cancel()
            loadTask = Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                do {
                    try await self.configureNetworkPolicy(for: load, on: webView)
                    try Task.checkCancellation()
                    guard self.loadedDescription == description else { return }
                    self.performConfiguredLoad(load, on: webView)
                } catch is CancellationError {
                    return
                } catch {
                    self.handleFailure(error)
                }
            }
        }

        private func configureNetworkPolicy(for load: TerminalWebArtifactLoad, on webView: WKWebView) async throws {
            let userContentController = webView.configuration.userContentController
            guard !load.allowsNetworkLoads else {
                userContentController.removeAllContentRuleLists()
                return
            }
            let ruleList = try await TerminalWebArtifactNetworkPolicy.makeNetworkBlockContentRuleList()
            try Task.checkCancellation()
            userContentController.removeAllContentRuleLists()
            userContentController.add(ruleList)
        }

        private func performConfiguredLoad(_ load: TerminalWebArtifactLoad, on webView: WKWebView) {
            switch load {
            case .fileURL(let url):
                // Read access is scoped to the single artifact file: a sibling `./style.css` reference in
                // the HTML is intentionally unreachable. Terminal HTML artifacts are treated as standalone
                // documents; loading a whole directory to satisfy relative asset refs is out of scope.
                webView.loadFileURL(url, allowingReadAccessTo: url)
            case .request(let url):
                webView.load(URLRequest(url: url))
            case .htmlString(let html):
                webView.loadHTMLString(html, baseURL: nil)
            }
        }

        private static func identity(for load: TerminalWebArtifactLoad) -> String {
            switch load {
            case .fileURL(let url): return "file:\(url.absoluteString)"
            case .request(let url): return "request:\(url.absoluteString)"
            case .htmlString(let html): return "html:\(html.hashValue)"
            }
        }

        private func observe(_ webView: WKWebView) {
            observations = [
                webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, change in
                    guard let newValue = change.newValue else { return }
                    Task { @MainActor [weak self] in self?.model.progress = newValue }
                },
                webView.observe(\.isLoading, options: [.new]) { [weak self] _, change in
                    guard let newValue = change.newValue else { return }
                    Task { @MainActor [weak self] in self?.model.isLoading = newValue }
                },
            ]
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor [weak self] in self?.model.loadErrorMessage = nil }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url,
                TerminalWebArtifactNetworkPolicy.shouldBlockNetworkLoad(networkLoadsAllowed: activeLoadAllowsNetwork, url: url)
            {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handleFailure(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleFailure(error)
        }

        private func handleFailure(_ error: Error) {
            let nsError = error as NSError
            // A superseding navigation surfaces as a cancellation, not a real failure worth showing.
            guard nsError.code != NSURLErrorCancelled else { return }
            let message = nsError.localizedDescription
            Task { @MainActor [weak self] in self?.model.loadErrorMessage = message }
        }
    }
}
