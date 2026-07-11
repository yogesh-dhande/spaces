import SwiftUI
import UIKit
import WebKit
import spacesterminalcore

/// Full-screen detail view for a workspace browser session, pushed from a browser-session row in the
/// workspace list. Loads the session's on-device proxy URL
/// (`http://<service>.<slug>.localhost:47898/...`) in an embedded `WKWebView`: the whole request/response
/// cycle is relayed by `SpacesMobileBrowserProxy` over the paired device's pinned-TLS Device API
/// connection, so this view never talks to the network directly.
///
/// Chrome mirrors `TerminalDetailView`'s fixed-dark detail screen (custom overlay bar, hidden navigation
/// bar) so the two full-screen detail surfaces read as the same product.
struct BrowserSessionDetailView: View {
    private static let chromeControlHeight: CGFloat = 36
    /// Matches `TerminalDetailView`'s fixed brand-dark background so this detail screen reads the same
    /// regardless of the app's light/dark appearance.
    private static let surfaceBackground = Color(red: 15 / 255, green: 21 / 255, blue: 23 / 255)

    let title: String
    let subtitle: String
    let request: BrowserProxyRequest
    let stagedScreenshots: StagedScreenshotStore
    let onBack: () -> Void

    @State private var model = BrowserSessionDetailViewModel()
    /// A freshly captured screenshot awaiting markup. Non-nil drives the full-screen QuickLook Markup
    /// presentation; the item carries the temp-file URL the editor annotates in place.
    @State private var markupItem: ScreenshotMarkupItem?
    /// True from the moment the screenshot button is tapped until the snapshot returns, so repeated taps
    /// can't queue overlapping captures.
    @State private var isCapturingScreenshot = false
    @State private var toast: ScreenshotToast?

    var body: some View {
        VStack(spacing: 0) {
            topOverlay
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 4)

            progressBar

            ZStack {
                BrowserSessionWebView(request: request, model: model)
                if let loadErrorMessage = model.loadErrorMessage {
                    errorState(loadErrorMessage)
                }
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    toastBanner(toast)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            bottomToolbar
        }
        .background(Self.surfaceBackground.ignoresSafeArea())
        .accessibilityIdentifier("browserSession.detail")
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(item: $markupItem) { item in
            ScreenshotMarkupPresenter(item: item, stagedScreenshots: stagedScreenshots) { outcome in
                markupItem = nil
                switch outcome {
                case .staged:
                    showToast("Screenshot staged — insert it from a terminal", isError: false)
                case .failed(let message):
                    showToast(message, isError: true)
                }
            }
            .ignoresSafeArea()
        }
        .task(id: toast?.id) {
            guard toast != nil else { return }
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation { toast = nil }
        }
    }

    private var topOverlay: some View {
        HStack(spacing: 8) {
            chromeButton(accessibilityIdentifier: "browserSession.back", accessibilityLabel: "Back", action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.subheadline.weight(.semibold))
            }

            Spacer(minLength: 0)

            VStack(spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.56))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
            Color.clear.frame(width: Self.chromeControlHeight, height: 1)
        }
        .frame(height: Self.chromeControlHeight)
    }

    /// Thin indeterminate-looking progress bar tracking `WKWebView.estimatedProgress`, shown only while
    /// a navigation is in flight.
    @ViewBuilder private var progressBar: some View {
        if model.isLoading {
            ProgressView(value: model.progress)
                .progressViewStyle(.linear)
                .tint(Theme.accent)
                .frame(height: 2)
                .accessibilityIdentifier("browserSession.progress")
        }
    }

    private var bottomToolbar: some View {
        HStack(spacing: 24) {
            toolbarButton(
                systemName: "chevron.left", accessibilityLabel: "Back", identifier: "browserSession.navigateBack", isEnabled: model.canGoBack
            ) {
                model.goBack?()
            }
            toolbarButton(
                systemName: "chevron.right", accessibilityLabel: "Forward", identifier: "browserSession.navigateForward",
                isEnabled: model.canGoForward
            ) {
                model.goForward?()
            }
            toolbarButton(systemName: "arrow.clockwise", accessibilityLabel: "Reload", identifier: "browserSession.reload", isEnabled: true) {
                model.reload?()
            }
            Spacer(minLength: 0)
            toolbarButton(
                systemName: "camera.viewfinder", accessibilityLabel: "Screenshot", identifier: "browserSession.screenshot",
                isEnabled: model.loadErrorMessage == nil && !isCapturingScreenshot
            ) {
                captureScreenshot()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.28))
    }

    private func toolbarButton(
        systemName: String, accessibilityLabel: String, identifier: String, isEnabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isEnabled ? .white : .white.opacity(0.28))
                .frame(width: Self.chromeControlHeight, height: Self.chromeControlHeight)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(identifier)
    }

    /// Captures the web view's visible viewport, then routes the result back through `handleCapturedSnapshot`
    /// on the main actor. `model.captureSnapshot` is wired by the web view's coordinator; it should always
    /// be present by the time the (page-loaded) button is enabled, so a missing hook just clears the
    /// in-flight flag rather than surfacing an error.
    private func captureScreenshot() {
        guard let capture = model.captureSnapshot else { return }
        isCapturingScreenshot = true
        capture { image in
            handleCapturedSnapshot(image)
        }
    }

    @MainActor
    private func handleCapturedSnapshot(_ image: UIImage?) {
        isCapturingScreenshot = false
        guard let image, let pngData = image.pngData() else {
            showToast("Couldn't capture this page.", isError: true)
            return
        }
        do {
            // Validate up front so an oversized capture is rejected before we write a temp file or open
            // the Markup editor. Markup can still grow the PNG past the cap, so the stage-on-dismiss
            // step re-validates too.
            _ = try TerminalImageAttachmentPayload.validated(fileExtension: "png", imageData: pngData)
        } catch {
            showToast(Self.screenshotErrorMessage(error), isError: true)
            return
        }
        let fileURL = FileManager.default.temporaryDirectory.appending(path: "spaces-screenshot-\(UUID().uuidString).png")
        do {
            try pngData.write(to: fileURL)
        } catch {
            showToast("Couldn't prepare this screenshot.", isError: true)
            return
        }
        markupItem = ScreenshotMarkupItem(fileURL: fileURL, sourceTitle: title)
    }

    static func screenshotErrorMessage(_ error: Error) -> String {
        if case TerminalImageAttachmentValidationError.imageTooLarge = error {
            return "Screenshot is too large to stage."
        }
        return "Couldn't stage this screenshot."
    }

    private func showToast(_ text: String, isError: Bool) {
        withAnimation { toast = ScreenshotToast(text: text, isError: isError) }
    }

    private func toastBanner(_ toast: ScreenshotToast) -> some View {
        HStack(spacing: 8) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(toast.isError ? Theme.orange : .white)
            Text(toast.text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .accessibilityIdentifier("browserSession.screenshotToast")
    }

    /// Shown only for a transport-level failure (e.g. the on-device proxy listener never bound). A
    /// routed request the proxy itself can't fulfill instead renders normally — the proxy answers with a
    /// self-contained styled HTML error page, which `WKWebView` treats as a successful load.
    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
            Text("Couldn't load this page")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Button("Retry") {
                model.retry?()
            }
            .buttonStyle(BrandPrimaryButtonStyle())
            .frame(width: 140)
            .accessibilityIdentifier("browserSession.retry")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Self.surfaceBackground)
        .accessibilityIdentifier("browserSession.error")
    }

    private func chromeButton<Label: View>(
        accessibilityIdentifier: String,
        accessibilityLabel: String,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
                .foregroundStyle(.white)
                .frame(height: Self.chromeControlHeight)
                .padding(.horizontal, 18)
                .background(
                    Capsule()
                        .fill(.black.opacity(0.28))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// Observable navigation state for the embedded browser session `WKWebView`. `BrowserSessionWebView`
/// (the `UIViewRepresentable`) keeps this in sync via KVO on the live web view and wires the
/// back/forward/reload/retry closures onto it, so `BrowserSessionDetailView` never needs to hold a
/// `WKWebView` reference of its own.
@MainActor
@Observable
final class BrowserSessionDetailViewModel {
    var isLoading = false
    var progress: Double = 0
    var canGoBack = false
    var canGoForward = false
    var loadErrorMessage: String?

    var goBack: (() -> Void)?
    var goForward: (() -> Void)?
    var reload: (() -> Void)?
    /// Captures the web view's visible viewport and delivers the image (or `nil` on failure) back on the
    /// main actor. Wired by the coordinator, which owns the live `WKWebView`.
    var captureSnapshot: ((@escaping @MainActor (UIImage?) -> Void) -> Void)?
    /// Re-issues the original request. Used by the Retry button instead of a plain `reload()` since a
    /// page that never committed (the transport-level failure case this button exists for) has nothing
    /// for `reload()` to reload.
    var retry: (() -> Void)?
}

/// A transient capsule banner shown over the browser content: the staged-screenshot confirmation or a
/// capture/validation failure. `id` changes on every post so `.task(id:)` restarts the auto-dismiss timer.
private struct ScreenshotToast: Equatable {
    let id = UUID()
    let text: String
    let isError: Bool
}

/// `WKWebView` wrapper for a browser session. Always uses `WKWebsiteDataStore.default()` so cookies and
/// local storage persist across visits the same way a real browser tab's would.
private struct BrowserSessionWebView: UIViewRepresentable {
    let request: BrowserProxyRequest
    let model: BrowserSessionDetailViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.attach(to: webView, initialRequest: request)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(request, on: webView)
    }

    /// Owns the KVO observers and navigation delegate callbacks. Network/WebKit callbacks are not
    /// guaranteed actor-isolated at the call site, so every callback hops onto the main actor before
    /// touching `model`, mirroring the hop pattern `BrowserProxySmokeTestModel` uses for its `NWListener`
    /// callbacks — and every hop carries only `Sendable` primitives extracted at the callback site rather
    /// than the (non-`Sendable`) `WKWebView`/`Error` the callback received.
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        private let model: BrowserSessionDetailViewModel
        private var loadedRequest: BrowserProxyRequest?
        private var loadGeneration = 0
        private var observations: [NSKeyValueObservation] = []

        init(model: BrowserSessionDetailViewModel) {
            self.model = model
        }

        func attach(to webView: WKWebView, initialRequest: BrowserProxyRequest) {
            model.goBack = { [weak webView] in webView?.goBack() }
            model.goForward = { [weak webView] in webView?.goForward() }
            model.reload = { [weak webView] in webView?.reload() }
            model.captureSnapshot = { [weak webView] completion in
                guard let webView else {
                    completion(nil)
                    return
                }
                // `takeSnapshot(with: nil)` captures the visible viewport. Its completion handler is
                // already `@MainActor`, so the image is delivered to our (also main-actor) completion
                // directly — no hop needed, unlike the KVO callbacks above.
                webView.takeSnapshot(with: nil) { image, _ in
                    completion(image)
                }
            }
            model.retry = { [weak self, weak webView] in
                guard let webView, let request = self?.loadedRequest else { return }
                webView.load(request.urlRequest)
            }
            observe(webView)
            load(initialRequest, on: webView)
        }

        func load(_ request: BrowserProxyRequest, on webView: WKWebView) {
            guard loadedRequest != request else { return }
            loadedRequest = request
            loadGeneration += 1
            let generation = loadGeneration
            webView.configuration.websiteDataStore.httpCookieStore.setCookie(request.httpCookie) { [weak self, weak webView] in
                Task { @MainActor [weak self, weak webView] in
                    guard let self, self.loadGeneration == generation, let webView else { return }
                    webView.load(request.urlRequest)
                }
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
                webView.observe(\.canGoBack, options: [.new]) { [weak self] _, change in
                    guard let newValue = change.newValue else { return }
                    Task { @MainActor [weak self] in self?.model.canGoBack = newValue }
                },
                webView.observe(\.canGoForward, options: [.new]) { [weak self] _, change in
                    guard let newValue = change.newValue else { return }
                    Task { @MainActor [weak self] in self?.model.canGoForward = newValue }
                },
            ]
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor [weak self] in self?.model.loadErrorMessage = nil }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handleFailure(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleFailure(error)
        }

        /// Only a transport-level failure reaches here (see the type doc comment); a routed request the
        /// proxy can't fulfill renders as a normal committed page instead.
        private func handleFailure(_ error: Error) {
            let nsError = error as NSError
            // A new navigation superseding an in-flight one surfaces as a cancellation, not a real
            // failure worth showing.
            guard nsError.code != NSURLErrorCancelled else { return }
            let message = nsError.localizedDescription
            Task { @MainActor [weak self] in self?.model.loadErrorMessage = message }
        }
    }
}
