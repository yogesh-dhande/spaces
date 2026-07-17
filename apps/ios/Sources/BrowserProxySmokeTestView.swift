#if DEBUG
    import Network
    import SwiftUI
    import WebKit

    /// DEBUG-only diagnostic that verifies `WKWebView` resolves `*.localhost`
    /// subdomains to loopback (RFC 6761) rather than attempting real DNS
    /// resolution.
    ///
    /// This stands in for the on-device browser-session proxy: a loopback
    /// `NWListener` answers on an ephemeral port, a bare `WKWebView` loads a
    /// `*.localhost` URL after the listener is ready, and PASS requires both a
    /// committed navigation and the listener observing the expected `Host`
    /// header — proving the request actually reached loopback instead of
    /// failing DNS or resolving somewhere else.
    struct BrowserProxySmokeTestView: View {
        @State private var model = BrowserProxySmokeTestModel()
        @State private var reloadToken = UUID()

        var body: some View {
            VStack(spacing: 0) {
                statusHeader
                Rectangle().fill(Theme.border).frame(height: 1)
                if let smokeURL = model.smokeURL {
                    WebProbeView(
                        url: smokeURL, reloadToken: reloadToken, onCommit: { model.recordNavigationCommit() },
                        onFail: { model.recordNavigationFailure($0) })
                } else {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.background(Theme.bg).navigationTitle("Browser Proxy Smoke Test").navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .primaryAction) { Button("Retry") { retry() } }
            }.task { model.start() }.onDisappear { model.stop() }
        }

        private var statusHeader: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    StatusDot(kind: statusDotKind)
                    Text(statusTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                }
                Text(statusDetailText).font(.footnote).foregroundStyle(Theme.muted)
                if let listenerErrorMessage = model.listenerErrorMessage { Text(listenerErrorMessage).font(.footnote).foregroundStyle(Theme.red) }
                if case .failed(let domain, let code, let description) = model.navigationOutcome {
                    Text("\(domain) (\(code)): \(description)").font(.footnote.monospaced()).foregroundStyle(Theme.red)
                }
                HStack(spacing: 8) {
                    Text(model.sawExpectedHost ? "Host header seen" : "Host header not seen")
                    Text("·")
                    Text(navigationStatusText)
                }.font(.system(size: 11)).foregroundStyle(Theme.muted)
            }.padding(14).background(Theme.surface)
        }

        private var isPassing: Bool { model.sawExpectedHost && model.navigationOutcome == .committed }

        private var isFailing: Bool { model.listenerErrorMessage != nil || isNavigationFailed }

        private var isNavigationFailed: Bool {
            if case .failed = model.navigationOutcome { return true }
            return false
        }

        private var statusDotKind: StatusDot.Kind {
            if isPassing { return .running }
            if isFailing { return .exited }
            return .waiting
        }

        private var statusTitle: String {
            if isPassing { return "PASS" }
            if isFailing { return "FAIL" }
            return "Checking…"
        }

        private var navigationStatusText: String {
            switch model.navigationOutcome {
            case .pending: "Navigation pending"
            case .committed: "Navigation committed"
            case .failed: "Navigation failed"
            }
        }

        private var statusDetailText: String {
            if let smokeURL = model.smokeURL, let listenerPort = model.listenerPort {
                return "Loads \(smokeURL.absoluteString) against a loopback listener on port \(listenerPort.rawValue)."
            }
            return "Starts a loopback listener on an ephemeral port, then loads a *.localhost URL against it."
        }

        private func retry() {
            reloadToken = UUID()
            model.start()
        }
    }

    /// Bare `WKWebView` wrapper. `reloadToken` changes drive a fresh `load`
    /// (used by the Retry button); navigation results are reported back
    /// through `onCommit`/`onFail` rather than exposed as view state, since
    /// the delegate callbacks arrive outside SwiftUI's update cycle.
    private struct WebProbeView: UIViewRepresentable {
        let url: URL
        let reloadToken: UUID
        let onCommit: @MainActor @Sendable () -> Void
        let onFail: @MainActor @Sendable (Error) -> Void

        func makeCoordinator() -> Coordinator { Coordinator(onCommit: onCommit, onFail: onFail) }

        func makeUIView(context: Context) -> WKWebView {
            let webView = WKWebView(frame: .zero)
            webView.navigationDelegate = context.coordinator
            context.coordinator.loadedToken = reloadToken
            webView.load(URLRequest(url: url))
            return webView
        }

        func updateUIView(_ webView: WKWebView, context: Context) {
            guard context.coordinator.loadedToken != reloadToken else { return }
            context.coordinator.loadedToken = reloadToken
            webView.load(URLRequest(url: url))
        }

        @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
            let onCommit: @MainActor @Sendable () -> Void
            let onFail: @MainActor @Sendable (Error) -> Void
            var loadedToken: UUID?

            init(onCommit: @escaping @MainActor @Sendable () -> Void, onFail: @escaping @MainActor @Sendable (Error) -> Void) {
                self.onCommit = onCommit
                self.onFail = onFail
            }

            func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { onCommit() }

            func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onFail(error) }

            func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { onFail(error) }
        }
    }

    /// Owns the loopback `NWListener` and reports observable results back to
    /// the view via `@Observable` state. Network framework callbacks arrive
    /// off the main thread; each one hops back via `Task { @MainActor in }`
    /// before touching model state, since this class is `@MainActor`-isolated
    /// (Swift 6 strict concurrency, no `DispatchQueue.main.async`).
    @MainActor @Observable final class BrowserProxySmokeTestModel {
        static let hostname = "smoke.abc123.localhost"
        static let expectedHostHeader = "Host: \(hostname)"

        static func makeSmokeURL(port: NWEndpoint.Port) -> URL { URL(string: "http://\(hostname):\(port.rawValue)/")! }

        enum NavigationOutcome: Equatable {
            case pending
            case committed
            case failed(domain: String, code: Int, description: String)
        }

        private(set) var sawExpectedHost = false
        private(set) var listenerErrorMessage: String?
        private(set) var navigationOutcome: NavigationOutcome = .pending
        private(set) var listenerPort: NWEndpoint.Port?
        private(set) var smokeURL: URL?

        private var listener: NWListener?
        private var connectionsByID: [ObjectIdentifier: NWConnection] = [:]

        /// Tears down any prior listener/connections and starts a fresh
        /// listener bound to an ephemeral loopback port. Safe to call repeatedly
        /// (used by the initial `.task` and by Retry).
        func start() {
            stop()
            sawExpectedHost = false
            listenerErrorMessage = nil
            navigationOutcome = .pending
            listenerPort = nil
            smokeURL = nil

            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)

            do {
                let listener = try NWListener(using: parameters)
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    Task { @MainActor in self.handleListenerState(state) }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { return }
                    Task { @MainActor in self.accept(connection) }
                }
                self.listener = listener
                listener.start(queue: .main)
            } catch { listenerErrorMessage = "Failed to start listener: \(error.localizedDescription)" }
        }

        func stop() {
            listener?.stateUpdateHandler = nil
            listener?.newConnectionHandler = nil
            listener?.cancel()
            listener = nil
            for connection in connectionsByID.values { connection.cancel() }
            connectionsByID.removeAll()
            listenerPort = nil
            smokeURL = nil
        }

        func recordNavigationCommit() { navigationOutcome = .committed }

        func recordNavigationFailure(_ error: Error) {
            let nsError = error as NSError
            navigationOutcome = .failed(domain: nsError.domain, code: nsError.code, description: nsError.localizedDescription)
        }

        private func handleListenerState(_ state: NWListener.State) {
            switch state {
            case .failed(let error):
                listenerErrorMessage = describeBindFailure(error)
                listenerPort = nil
                smokeURL = nil
                listener?.cancel()
                listener = nil
            case .waiting(let error):
                // Binding may surface as `.waiting` since Network.framework treats some
                // listener errors as retryable rather than immediately fatal.
                listenerErrorMessage = describeBindFailure(error)
                listenerPort = nil
                smokeURL = nil
            case .ready:
                listenerErrorMessage = nil
                guard let port = listener?.port else {
                    listenerErrorMessage = "Listener became ready without a local port."
                    listenerPort = nil
                    smokeURL = nil
                    return
                }
                listenerPort = port
                smokeURL = Self.makeSmokeURL(port: port)
            case .setup, .cancelled: break
            @unknown default: break
            }
        }

        private func describeBindFailure(_ error: NWError) -> String {
            if case .posix(let code) = error, code == .EADDRINUSE {
                return "The smoke-test loopback port is already in use. Retry to request another port."
            }
            return "Listener error: \(error.debugDescription)"
        }

        private func accept(_ connection: NWConnection) {
            let id = ObjectIdentifier(connection)
            connectionsByID[id] = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .failed = state { Task { @MainActor in self.removeConnection(id) } }
            }
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
                guard let self else { return }
                Task { @MainActor in self.handleReceive(connection: connection, id: id, data: data) }
            }
        }

        private func handleReceive(connection: NWConnection, id: ObjectIdentifier, data: Data?) {
            // The connection may already have been torn down (e.g. peer reset) by the
            // time this hops back onto the main actor; ignore stale callbacks.
            guard connectionsByID[id] != nil else { return }
            if let data, let head = String(data: data, encoding: .utf8), head.contains(Self.expectedHostHeader) { sawExpectedHost = true }
            respond(on: connection, id: id)
        }

        private func respond(on connection: NWConnection, id: ObjectIdentifier) {
            let body = "<h1>smoke ok</h1>"
            let response =
                "HTTP/1.1 200 OK\r\n" + "Content-Type: text/html; charset=utf-8\r\n" + "Content-Length: \(body.utf8.count)\r\n"
                + "Connection: close\r\n" + "\r\n" + body
            connection.send(
                content: Data(response.utf8),
                completion: .contentProcessed { [weak self] _ in
                    guard let self else {
                        connection.cancel()
                        return
                    }
                    Task { @MainActor in self.removeConnection(id) }
                })
        }

        private func removeConnection(_ id: ObjectIdentifier) { if let connection = connectionsByID.removeValue(forKey: id) { connection.cancel() } }
    }
#endif
