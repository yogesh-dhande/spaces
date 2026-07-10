#if canImport(AppKit)
    import AppKit
    import CryptoKit
    import Foundation
    import spacesdevicecore
    import spacesterminalcore
    import spacesterminalghostty

    /// Late-bound holder wiring a terminal pane's Ghostty link handler to its coordinator.
    ///
    /// The pane's `sessionHostProvider` closure (and therefore the mirror view's `onOpenLink`) is
    /// captured when the pane view controller is constructed, but the coordinator can only be built
    /// afterward because it needs the pane's view for its banner. This box is captured by that closure
    /// up front and its coordinator is filled in once both exist. The reference is `weak` so the box
    /// (retained by the long-lived host/view) never keeps a torn-down coordinator alive.
    @MainActor final class TerminalLinkOpenHandlerBox {
        weak var coordinator: TerminalLinkOpenCoordinator?
        func open(_ rawLink: String) { coordinator?.openLink(rawLink) }
    }

    /// Per-pane router for terminal link clicks on macOS. One instance per terminal pane, owned by the
    /// pane's `TerminalPaneContentController`.
    ///
    /// Routing of a raw clicked string (via `SpacesDeviceTerminalLinkClassifier.route(for:)`):
    /// - web URL: opened in the default browser through the artifact registry.
    /// - loopback URL: on the local device it opens normally; on a remote device it can't be reached
    ///   from here yet, so a notice banner explains that instead of a doomed connection.
    /// - file link on the local device: resolved and opened directly with no daemon round trip and no
    ///   type/path restrictions, deliberately preserving macOS "open anything local" semantics.
    /// - file link on a remote device: resolved and fetched over the Device API into a temp cache, then
    ///   opened by artifact category. A second click supersedes an in-flight fetch.
    @MainActor final class TerminalLinkOpenCoordinator {
        private struct LinkOpenError: LocalizedError {
            let message: String
            var errorDescription: String? { message }
        }

        static let loopbackRemoteNotice =
            "This address runs on the session's host machine and isn't reachable from this device yet."

        private let sessionID: String
        private let deviceID: String
        private let isLocalDevice: Bool
        private let workingDirectoryProvider: @MainActor () -> String?
        private let requestSender: RemoteGhosttyTerminalServiceRequestSender
        private let registry: TerminalArtifactHandlerRegistry
        private let banner: any TerminalLinkActivityBannerPresenting

        /// Bumped on every click. An async fetch captures the value at its start and abandons its result
        /// if a newer click has since superseded it, so a stale resolve/download never opens a file or
        /// updates the banner after the user moved on.
        private var generation: UInt64 = 0
        private var activeTask: Task<Void, Never>?

        /// The temp-directory GC is a whole-app concern, not a per-pane one, so it runs once per launch.
        @MainActor private static var didRunCacheGC = false

        private static var cacheDirectory: URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("SpacesTerminalLinkArtifacts", isDirectory: true)
        }

        init(
            sessionID: String, deviceID: String, isLocalDevice: Bool,
            workingDirectoryProvider: @escaping @MainActor () -> String?,
            requestSender: @escaping RemoteGhosttyTerminalServiceRequestSender,
            registry: TerminalArtifactHandlerRegistry = .defaultRegistry(),
            banner: any TerminalLinkActivityBannerPresenting
        ) {
            self.sessionID = sessionID
            self.deviceID = deviceID
            self.isLocalDevice = isLocalDevice
            self.workingDirectoryProvider = workingDirectoryProvider
            self.requestSender = requestSender
            self.registry = registry
            self.banner = banner
        }

        deinit { MainActor.assumeIsolated { activeTask?.cancel() } }

        // MARK: - Routing

        func openLink(_ rawLink: String) {
            // Every click supersedes any in-flight fetch and clears its banner before routing anew.
            cancelActiveOpen()
            guard let route = SpacesDeviceTerminalLinkClassifier.route(for: rawLink) else { return }
            switch route {
            case .webURL(let url):
                _ = registry.open(url, as: .webURL)
            case .loopbackURL(let url):
                if isLocalDevice {
                    _ = registry.open(url, as: .webURL)
                } else {
                    banner.showNotice(Self.loopbackRemoteNotice)
                }
            case .fileLink(let raw):
                if isLocalDevice {
                    openLocalFileLink(raw)
                } else {
                    startRemoteFileOpen(raw)
                }
            }
        }

        /// Cancels any in-flight remote fetch, invalidates its generation, and hides the banner.
        /// Called on each new click, on the banner's Cancel affordance, and on pane teardown.
        func cancelActiveOpen() {
            generation &+= 1
            activeTask?.cancel()
            activeTask = nil
            banner.dismiss()
        }

        // MARK: - Local files

        private func openLocalFileLink(_ raw: String) {
            // No daemon round trip and no type/path restrictions: opening a local file preserves macOS
            // "open anything" semantics (a `.swift` path opens the user's editor, a `.png` opens Preview,
            // etc.), so the coordinator only expands the path and confirms the file is there.
            guard let url = GhosttyTerminalLinkOpener.resolvedURL(for: raw, workingDirectory: workingDirectoryProvider()) else {
                banner.showError("Couldn't resolve “\(raw)”.")
                return
            }
            if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) {
                banner.showError("File not found: \(url.lastPathComponent)")
                return
            }
            _ = registry.openLocalFile(at: url)
        }

        // MARK: - Remote files

        private func startRemoteFileOpen(_ raw: String) {
            let generationAtStart = generation
            banner.showProgress(message: "Resolving link…", onCancel: { [weak self] in self?.cancelActiveOpen() })
            Self.runCacheGCIfNeeded()
            activeTask = Task { @MainActor [weak self] in
                await self?.performRemoteFileOpen(raw, generation: generationAtStart)
            }
        }

        private func performRemoteFileOpen(_ raw: String, generation generationAtStart: UInt64) async {
            let sessionID = self.sessionID
            let sender = self.requestSender

            let resolveResult = await Self.send(
                TerminalServiceRequest(command: .resolveTerminalLink(.init(sessionID: sessionID, terminalLink: raw))), using: sender)
            guard isCurrent(generationAtStart) else { return }

            let metadata: TerminalServiceTerminalLinkMetadata
            switch resolveResult {
            case .failure(let error):
                finishWithError(error.localizedDescription, generation: generationAtStart)
                return
            case .success(let response):
                guard response.ok else {
                    finishWithError(response.message, generation: generationAtStart)
                    return
                }
                guard let resolved = response.terminalLinkMetadata else {
                    finishWithError("The session's host didn't return link details.", generation: generationAtStart)
                    return
                }
                metadata = resolved
            }

            // The route already caught web URLs, so a resolved external URL is not expected here; honor it
            // anyway by opening it in the browser, since that is the only thing an external result allows.
            if metadata.source == SpacesDeviceTerminalLinkSource.externalURL.rawValue {
                if let externalURL = metadata.externalURL, let url = URL(string: externalURL) {
                    _ = registry.open(url, as: .webURL)
                    finishSuccess(generation: generationAtStart)
                } else {
                    finishWithError("The link points to an external address that couldn't be opened.", generation: generationAtStart)
                }
                return
            }

            let cacheURL: URL
            do {
                cacheURL = try makeCacheURL(for: metadata)
            } catch {
                finishWithError(error.localizedDescription, generation: generationAtStart)
                return
            }

            if isCacheHit(cacheURL, byteCount: metadata.byteCount) {
                openArtifact(at: cacheURL, metadata: metadata)
                finishSuccess(generation: generationAtStart)
                return
            }

            banner.showProgress(message: "Fetching \(metadata.displayName)…", onCancel: { [weak self] in self?.cancelActiveOpen() })

            do {
                try await Self.downloadArtifact(
                    sessionID: sessionID, linkID: metadata.id, expectedByteCount: metadata.byteCount, to: cacheURL, using: sender)
            } catch {
                guard isCurrent(generationAtStart) else { return }
                // A cancelled transfer was already superseded by a newer click (which owns the banner now).
                if error is CancellationError { return }
                finishWithError(error.localizedDescription, generation: generationAtStart)
                return
            }

            guard isCurrent(generationAtStart) else { return }
            openArtifact(at: cacheURL, metadata: metadata)
            finishSuccess(generation: generationAtStart)
        }

        private func openArtifact(at url: URL, metadata: TerminalServiceTerminalLinkMetadata) {
            if let kindRaw = metadata.artifactKind, let kind = SpacesDeviceTerminalLinkArtifactKind(rawValue: kindRaw) {
                _ = registry.open(url, as: TerminalArtifactCategory(kind: kind))
            } else {
                // Unknown or missing kind: fall back to extension-based classification (open-anything).
                _ = registry.openLocalFile(at: url)
            }
        }

        // MARK: - Completion helpers

        private func isCurrent(_ generationAtStart: UInt64) -> Bool { generation == generationAtStart && !Task.isCancelled }

        private func finishSuccess(generation generationAtStart: UInt64) {
            guard generation == generationAtStart else { return }
            activeTask = nil
            banner.dismiss()
        }

        private func finishWithError(_ message: String, generation generationAtStart: UInt64) {
            guard generation == generationAtStart else { return }
            activeTask = nil
            banner.showError(message)
        }

        // MARK: - Cache

        private func makeCacheURL(for metadata: TerminalServiceTerminalLinkMetadata) throws -> URL {
            try FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
            let fallbackExtension = URL(fileURLWithPath: metadata.displayName).pathExtension
            let fileExtension = SpacesDeviceTerminalLinkClassifier.preferredFilenameExtension(
                contentType: metadata.contentType, fallback: fallbackExtension)
            let identity = Data("\(deviceID)|\(sessionID)|\(metadata.id)".utf8)
            let digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
            return Self.cacheDirectory.appendingPathComponent("\(digest).\(fileExtension)")
        }

        private func isCacheHit(_ url: URL, byteCount: Int64?) -> Bool {
            guard let byteCount, byteCount >= 0 else { return false }
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 else { return false }
            return size == byteCount
        }

        /// Removes cached artifacts older than 24h, once per app run. Mirrors the iOS preview-cache GC but
        /// stays local to the coordinator. Runs off the main actor since it scans the temp directory.
        private static func runCacheGCIfNeeded() {
            guard !didRunCacheGC else { return }
            didRunCacheGC = true
            let directory = cacheDirectory
            Task.detached(priority: .utility) {
                guard
                    let files = try? FileManager.default.contentsOfDirectory(
                        at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
                else { return }
                let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
                for file in files {
                    let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    guard let modifiedAt = values?.contentModificationDate, modifiedAt < cutoff else { continue }
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }

        // MARK: - Device API

        /// The request sender does blocking pinned-TLS I/O, so every call runs off the main actor.
        private static func send(_ request: TerminalServiceRequest, using sender: @escaping RemoteGhosttyTerminalServiceRequestSender) async
            -> Result<TerminalServiceResponse, Error>
        {
            await Task.detached(priority: .userInitiated) {
                do { return .success(try sender(request)) } catch { return .failure(error) }
            }.value
        }

        /// Runs off the main actor (nonisolated) so the chunk-reader closure handed to the shared
        /// transfer helper is not main-actor-isolated. Honors `Task` cancellation via the helper.
        private nonisolated static func downloadArtifact(
            sessionID: String, linkID: String, expectedByteCount: Int64?, to destination: URL,
            using sender: @escaping RemoteGhosttyTerminalServiceRequestSender
        ) async throws {
            try await SpacesDeviceTerminalLinkChunkTransfer.download(
                linkID: linkID, expectedByteCount: expectedByteCount, to: destination
            ) { offset, limit in
                try await readChunk(sessionID: sessionID, linkID: linkID, offset: offset, limit: limit, using: sender)
            }
        }

        private static func readChunk(
            sessionID: String, linkID: String, offset: Int64, limit: Int, using sender: @escaping RemoteGhosttyTerminalServiceRequestSender
        ) async throws -> SpacesDeviceTerminalLinkChunk {
            let response = try await Task.detached(priority: .userInitiated) {
                try sender(
                    TerminalServiceRequest(
                        command: .readTerminalLinkChunk(.init(sessionID: sessionID, terminalLinkID: linkID, offset: offset, limit: limit))))
            }.value
            guard response.ok else { throw LinkOpenError(message: response.message) }
            guard let wire = response.terminalLinkChunk else {
                throw LinkOpenError(message: "The session's host returned no data for the link.")
            }
            return SpacesDeviceTerminalLinkChunk(
                linkID: wire.linkID, offset: wire.offset, byteCount: wire.byteCount, isFinal: wire.isFinal, base64Data: wire.base64Data)
        }
    }
#endif
