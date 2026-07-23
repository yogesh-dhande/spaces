#if canImport(AppKit)
    import AppKit
    import CryptoKit
    import Foundation
    import spacesdevicecore
    import spacesterminalcore
    import spacesterminalghostty
    import spacesterminalui

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
    /// - `spaces://terminal/…` deep link: focused in-app through the host's shared handler (same path as
    ///   the OS URL handler), so a click never leaves the app. An unqualified link (no `?device=`) means
    ///   "the device this text came from": remote daemons always print same-device links unqualified
    ///   because a device can't know the client-side id it is paired under, so on a remote pane the link
    ///   is stamped with the pane's own device before routing.
    @MainActor final class TerminalLinkOpenCoordinator {
        private struct LinkOpenError: LocalizedError {
            let message: String
            var errorDescription: String? { message }
        }

        static let loopbackRemoteNotice = "This address runs on the session's host machine and isn't reachable from this device yet."

        private let sessionID: String
        private let deviceID: String
        private let isLocalDevice: Bool
        private let workingDirectoryProvider: @MainActor () -> String?
        private let requestSender: RemoteGhosttyTerminalServiceRequestSender
        private let registry: TerminalArtifactHandlerRegistry
        private let banner: any TerminalPaneBannerPresenting
        /// Focuses a clicked `spaces://terminal/…` session in-app (no OS round trip). The host
        /// (`AppKitController`) owns the same device-resolution + focus path the URL handler uses, so
        /// both entry points share one behavior and one other-device alert.
        private let openSpacesTerminalLink: @MainActor (SpacesTerminalDeepLink) -> Void

        /// Bumped on every click. An async fetch captures the value at its start and abandons its result
        /// if a newer click has since superseded it, so a stale resolve/download never opens a file or
        /// updates the banner after the user moved on.
        private var generation: UInt64 = 0
        private var activeTask: Task<Void, Never>?

        /// Every task this coordinator has spawned and not yet finished, keyed by a token minted
        /// before the task exists (so the task never has to reference its own `Task` handle from
        /// inside its own closure — the classic self-referencing-`var` pattern is what Swift 6
        /// strict concurrency flags as a data race) and removed in a `defer` when the body returns.
        /// `activeTask` remains the *current* fetch for `cancelActiveOpen()`'s purposes, but a fetch
        /// a newer click has superseded stays in this dictionary — no longer "active", but not yet
        /// finished — until its own late completion actually runs its course (discarding its result
        /// via `isCurrent`, per the class doc). `drainActiveWorkForTesting()` awaits this dictionary
        /// down to empty, so a test can assert on final state deterministically instead of guessing
        /// a settle window for a cancelled late finisher.
        private var inFlightOpenTasks: [UUID: Task<Void, Never>] = [:]

        /// The temp-directory GC is a whole-app concern, not a per-pane one, so it runs once per launch.
        @MainActor private static var didRunCacheGC = false

        private static var cacheDirectory: URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("SpacesTerminalLinkArtifacts", isDirectory: true)
        }

        init(
            sessionID: String, deviceID: String, isLocalDevice: Bool, workingDirectoryProvider: @escaping @MainActor () -> String?,
            requestSender: @escaping RemoteGhosttyTerminalServiceRequestSender, registry: TerminalArtifactHandlerRegistry = .defaultRegistry(),
            banner: any TerminalPaneBannerPresenting, openSpacesTerminalLink: @escaping @MainActor (SpacesTerminalDeepLink) -> Void
        ) {
            self.sessionID = sessionID
            self.deviceID = deviceID
            self.isLocalDevice = isLocalDevice
            self.workingDirectoryProvider = workingDirectoryProvider
            self.requestSender = requestSender
            self.registry = registry
            self.banner = banner
            self.openSpacesTerminalLink = openSpacesTerminalLink
        }

        deinit { MainActor.assumeIsolated { activeTask?.cancel() } }

        // MARK: - Routing

        func openLink(_ rawLink: String) {
            // Every click supersedes any in-flight fetch and clears its banner before routing anew.
            cancelActiveOpen()
            guard let route = SpacesDeviceTerminalLinkClassifier.route(for: rawLink) else { return }
            switch route {
            case .webURL(let url): _ = registry.open(url, as: .webURL)
            case .loopbackURL(let url): if isLocalDevice { _ = registry.open(url, as: .webURL) } else { banner.showNotice(Self.loopbackRemoteNotice) }
            case .fileLink(let raw): if isLocalDevice { openLocalFileLink(raw) } else { startRemoteFileOpen(raw) }
            case .spacesTerminal(let link): openSpacesTerminalLink(qualifiedDeepLink(link))
            }
        }

        /// Qualifies a clicked terminal deep link with the device the clicked text came from. An
        /// unqualified `spaces://terminal/<id>` (no `?device=`) means "this pane's device": remote
        /// daemons print same-device links unqualified because a device can't know the client-side id it
        /// is paired under. An explicit qualifier is always honored, and on a local pane a nil qualifier
        /// already resolves to this Mac, so only a remote pane's unqualified link needs stamping.
        private func qualifiedDeepLink(_ link: SpacesTerminalDeepLink) -> SpacesTerminalDeepLink {
            guard link.deviceID == nil, !isLocalDevice else { return link }
            return SpacesTerminalDeepLink(sessionID: link.sessionID, deviceID: deviceID)
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
            startCacheGCIfNeeded()
            let taskID = UUID()
            let task = Task { @MainActor [weak self] in
                defer { self?.inFlightOpenTasks[taskID] = nil }
                await self?.performRemoteFileOpen(raw, generation: generationAtStart)
            }
            inFlightOpenTasks[taskID] = task
            activeTask = task
        }

        /// Awaits every task this coordinator has in flight: the current fetch, any fetch a newer
        /// click has since cancelled and superseded (`Task.value` on a cancelled task still awaits
        /// its actual completion, so a late finisher unblocked well after being cancelled is not
        /// still running once this returns), and the one-time cache GC. Loops because draining one
        /// task can let another appear in the meantime (a new click while draining). Returns once no
        /// task remains — the seam a test drains after a click instead of polling the recorder/banner
        /// against a settle window.
        func drainActiveWorkForTesting() async {
            while let (_, task) = inFlightOpenTasks.first {
                await task.value
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
            do { cacheURL = try makeCacheURL(for: metadata) } catch {
                finishWithError(error.localizedDescription, generation: generationAtStart)
                return
            }

            if isCacheHit(cacheURL, metadata: metadata) {
                openArtifact(at: cacheURL, metadata: metadata)
                finishSuccess(generation: generationAtStart)
                return
            }

            banner.showProgress(message: "Fetching \(metadata.displayName)…", onCancel: { [weak self] in self?.cancelActiveOpen() })

            let temporaryURL = temporaryCacheURL(for: cacheURL)
            var didMoveTemporaryFile = false
            defer { if !didMoveTemporaryFile { try? FileManager.default.removeItem(at: temporaryURL) } }
            do {
                try await Self.downloadArtifact(
                    sessionID: sessionID, linkID: metadata.id, expectedByteCount: metadata.byteCount, to: temporaryURL, using: sender)
            } catch {
                guard isCurrent(generationAtStart) else { return }
                // A cancelled transfer was already superseded by a newer click (which owns the banner now).
                if error is CancellationError { return }
                finishWithError(error.localizedDescription, generation: generationAtStart)
                return
            }

            guard isCurrent(generationAtStart) else { return }
            do {
                try? FileManager.default.removeItem(at: cacheURL)
                try FileManager.default.moveItem(at: temporaryURL, to: cacheURL)
                didMoveTemporaryFile = true
            } catch {
                finishWithError(error.localizedDescription, generation: generationAtStart)
                return
            }
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
            // The daemon-generated link id carries the canonical path plus file freshness fields, so a
            // same-size rewrite resolves to a different cache entry instead of hitting stale bytes.
            let identity = Data("\(deviceID)|\(sessionID)|\(metadata.id)".utf8)
            let digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
            return Self.cacheDirectory.appendingPathComponent("\(digest).\(fileExtension)")
        }

        private func temporaryCacheURL(for cacheURL: URL) -> URL {
            cacheURL.deletingLastPathComponent().appendingPathComponent(".\(cacheURL.lastPathComponent).\(UUID().uuidString).download")
        }

        private func isCacheHit(_ url: URL, metadata: TerminalServiceTerminalLinkMetadata) -> Bool {
            // The cache path is keyed by `metadata.id`; the size check only confirms the cached file is
            // complete for that freshness-keyed artifact.
            let byteCount = metadata.byteCount
            guard let byteCount, byteCount >= 0 else { return false }
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 else { return false }
            return size == byteCount
        }

        /// Removes cached artifacts older than 24h, once per app run. Mirrors the iOS preview-cache GC but
        /// stays local to the coordinator. Runs off the main actor since it scans the temp directory.
        ///
        /// This used to fire a bare `Task.detached` that no one awaited, escaping `activeTask`
        /// tracking entirely — the one genuinely fire-and-forget task in this file, since the
        /// download/chunk-read detached tasks elsewhere are all immediately `await`ed by their
        /// caller. It is folded into `inFlightOpenTasks` the same way as a fetch, so
        /// `drainActiveWorkForTesting()` also accounts for it on the one run where it actually fires.
        private func startCacheGCIfNeeded() {
            guard !Self.didRunCacheGC else { return }
            Self.didRunCacheGC = true
            let directory = Self.cacheDirectory
            let taskID = UUID()
            let task = Task { @MainActor [weak self] in
                defer { self?.inFlightOpenTasks[taskID] = nil }
                await Task.detached(priority: .utility) {
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
                }.value
            }
            inFlightOpenTasks[taskID] = task
        }

        // MARK: - Device API

        /// The request sender does blocking pinned-TLS I/O, so every call runs off the main actor.
        private static func send(_ request: TerminalServiceRequest, using sender: @escaping RemoteGhosttyTerminalServiceRequestSender) async
            -> Result<TerminalServiceResponse, Error>
        { await Task.detached(priority: .userInitiated) { do { return .success(try sender(request)) } catch { return .failure(error) } }.value }

        /// Runs off the main actor (nonisolated) so the chunk-reader closure handed to the shared
        /// transfer helper is not main-actor-isolated. Honors `Task` cancellation via the helper.
        private nonisolated static func downloadArtifact(
            sessionID: String, linkID: String, expectedByteCount: Int64?, to destination: URL,
            using sender: @escaping RemoteGhosttyTerminalServiceRequestSender
        ) async throws {
            try await SpacesDeviceTerminalLinkChunkTransfer.download(linkID: linkID, expectedByteCount: expectedByteCount, to: destination) {
                offset, limit in try await readChunk(sessionID: sessionID, linkID: linkID, offset: offset, limit: limit, using: sender)
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
            guard let wire = response.terminalLinkChunk else { throw LinkOpenError(message: "The session's host returned no data for the link.") }
            return SpacesDeviceTerminalLinkChunk(
                linkID: wire.linkID, offset: wire.offset, byteCount: wire.byteCount, isFinal: wire.isFinal, base64Data: wire.base64Data)
        }
    }
#endif
