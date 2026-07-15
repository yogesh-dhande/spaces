import Foundation
import Testing
import spacesdevicecore
import spacesterminalcore
import spacesterminalghostty

@testable import spacesui

/// Exercises `TerminalLinkOpenCoordinator`'s routing of clicked terminal links: web/loopback/local/remote
/// dispatch, the remote fetch-and-open flow with its cache, and click supersession. The coordinator's
/// three collaborators are faked — a recording banner (`TerminalLinkActivityBannerPresenting`), a recording
/// artifact registry (real `TerminalArtifactHandlerRegistry` with capturing handlers), and a scripted
/// request sender — so no AppKit view tree, browser, or Device API connection is involved.
@MainActor struct TerminalLinkOpenCoordinatorTests {
    // MARK: - Fakes

    @MainActor private final class RecordingBanner: TerminalLinkActivityBannerPresenting {
        var progressMessages: [String] = []
        var errorMessages: [String] = []
        var noticeMessages: [String] = []
        var dismissCount = 0
        private(set) var lastCancel: (@MainActor () -> Void)?

        func showProgress(message: String, onCancel: @escaping @MainActor () -> Void) {
            progressMessages.append(message)
            lastCancel = onCancel
        }
        func showError(_ message: String) { errorMessages.append(message) }
        func showNotice(_ message: String) { noticeMessages.append(message) }
        func dismiss() { dismissCount += 1 }
    }

    @MainActor private final class OpenRecorder {
        struct Open {
            let category: TerminalArtifactCategory?
            let url: URL
        }
        var opens: [Open] = []

        func makeRegistry() -> TerminalArtifactHandlerRegistry {
            let categories: [TerminalArtifactCategory] = [.image, .video, .pdf, .markdown, .text, .html, .webURL]
            var handlers: [TerminalArtifactCategory: TerminalArtifactHandlerRegistry.Handler] = [:]
            for category in categories {
                handlers[category] = { [weak self] url in
                    self?.opens.append(Open(category: category, url: url))
                    return true
                }
            }
            return TerminalArtifactHandlerRegistry(
                handlers: handlers,
                defaultOpenHandler: { [weak self] url in
                    self?.opens.append(Open(category: nil, url: url))
                    return true
                })
        }
    }

    private final class FakeLinkSender: @unchecked Sendable {
        private let lock = NSLock()
        private var resolveByLink: [String: TerminalServiceResponse] = [:]
        private var throwingLinks: Set<String> = []
        private var chunkByLinkID: [String: TerminalServiceTerminalLinkChunk] = [:]
        private var gatesByLinkID: [String: [DispatchSemaphore]] = [:]
        private var resolveCounts = 0
        private var chunkCounts: [String: Int] = [:]

        func setResolve(_ response: TerminalServiceResponse, forLink link: String) { lock.withLock { resolveByLink[link] = response } }
        func setResolveThrows(forLink link: String) { lock.withLock { _ = throwingLinks.insert(link) } }
        func setChunk(_ chunk: TerminalServiceTerminalLinkChunk, forLinkID linkID: String) { lock.withLock { chunkByLinkID[linkID] = chunk } }
        func setChunkGate(_ gate: DispatchSemaphore, forLinkID linkID: String) { lock.withLock { gatesByLinkID[linkID] = [gate] } }
        func chunkCount(forLinkID linkID: String) -> Int { lock.withLock { chunkCounts[linkID] ?? 0 } }
        func resetChunkCount(forLinkID linkID: String) { lock.withLock { chunkCounts[linkID] = 0 } }

        func send(_ request: TerminalServiceRequest) throws -> TerminalServiceResponse {
            switch request.command {
            case .resolveTerminalLink(let payload):
                let link = payload.terminalLink ?? ""
                let shouldThrow: Bool = lock.withLock {
                    resolveCounts += 1
                    return throwingLinks.contains(link)
                }
                if shouldThrow { throw NSError(domain: "FakeLinkSender", code: 1, userInfo: [NSLocalizedDescriptionKey: "resolve exploded"]) }
                return lock.withLock { resolveByLink[link] } ?? TerminalServiceResponse(ok: false, message: "no resolve scripted for \(link)")
            case .readTerminalLinkChunk(let payload):
                let linkID = payload.terminalLinkID ?? ""
                let gate: DispatchSemaphore? = lock.withLock {
                    chunkCounts[linkID, default: 0] += 1
                    guard var gates = gatesByLinkID[linkID], !gates.isEmpty else { return nil }
                    let gate = gates.removeFirst()
                    gatesByLinkID[linkID] = gates
                    return gate
                }
                gate?.wait()
                guard let chunk = lock.withLock({ chunkByLinkID[linkID] }) else {
                    return TerminalServiceResponse(ok: false, message: "no chunk scripted for \(linkID)")
                }
                return TerminalServiceResponse(ok: true, message: "", terminalLinkChunk: chunk)
            default: return TerminalServiceResponse(ok: false, message: "unexpected command \(request.command.name)")
            }
        }
    }

    // MARK: - Helpers

    private func makeCoordinator(
        isLocalDevice: Bool, workingDirectory: String? = nil, sender: FakeLinkSender = FakeLinkSender(), banner: RecordingBanner,
        recorder: OpenRecorder, sessionID: String = "session-\(UUID().uuidString)", deviceID: String? = nil,
        onSpacesTerminalLink: @escaping @MainActor (SpacesTerminalDeepLink) -> Void = { _ in }
    ) -> TerminalLinkOpenCoordinator {
        TerminalLinkOpenCoordinator(
            sessionID: sessionID, deviceID: deviceID ?? (isLocalDevice ? "local" : "remote-\(UUID().uuidString)"), isLocalDevice: isLocalDevice,
            workingDirectoryProvider: { workingDirectory }, requestSender: { [sender] request in try sender.send(request) },
            registry: recorder.makeRegistry(), banner: banner, openSpacesTerminalLink: onSpacesTerminalLink)
    }

    private func metadata(
        id: String, source: SpacesDeviceTerminalLinkSource = .localFile, displayName: String, contentType: String?, artifactKind: String?,
        byteCount: Int64?, externalURL: String? = nil, originalLink: String = "link"
    ) -> TerminalServiceTerminalLinkMetadata {
        TerminalServiceTerminalLinkMetadata(
            id: id, source: source.rawValue, originalLink: originalLink, displayName: displayName, contentType: contentType,
            artifactKind: artifactKind, byteCount: byteCount, externalURL: externalURL)
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ predicate: @MainActor () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !predicate(), clock.now < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Synchronous routes

    @Test func webURLRoutesToBrowserHandler() {
        let banner = RecordingBanner()
        let recorder = OpenRecorder()
        let coordinator = makeCoordinator(isLocalDevice: false, banner: banner, recorder: recorder)

        coordinator.openLink("https://example.com/report")

        #expect(recorder.opens.count == 1)
        #expect(recorder.opens.first?.category == .webURL)
        #expect(recorder.opens.first?.url.absoluteString == "https://example.com/report")
        #expect(banner.errorMessages.isEmpty)
        #expect(banner.noticeMessages.isEmpty)
    }

    @Test func loopbackURLOnLocalDeviceOpensWithoutRequest() {
        let banner = RecordingBanner()
        let recorder = OpenRecorder()
        let sender = FakeLinkSender()
        let coordinator = makeCoordinator(isLocalDevice: true, sender: sender, banner: banner, recorder: recorder)

        coordinator.openLink("http://localhost:3000/app")

        #expect(recorder.opens.first?.category == .webURL)
        #expect(recorder.opens.first?.url.absoluteString == "http://localhost:3000/app")
        #expect(banner.noticeMessages.isEmpty)
    }

    @Test func loopbackURLOnRemoteDeviceShowsNoticeWithoutRequest() {
        let banner = RecordingBanner()
        let recorder = OpenRecorder()
        let coordinator = makeCoordinator(isLocalDevice: false, banner: banner, recorder: recorder)

        coordinator.openLink("http://127.0.0.1:8080/")

        #expect(recorder.opens.isEmpty)
        #expect(banner.noticeMessages == [TerminalLinkOpenCoordinator.loopbackRemoteNotice])
    }

    @Test func spacesTerminalDeepLinkRoutesToInAppHandlerWithoutOpeningArtifact() {
        let banner = RecordingBanner()
        let recorder = OpenRecorder()
        var routed: [SpacesTerminalDeepLink] = []
        let coordinator = makeCoordinator(
            isLocalDevice: true, banner: banner, recorder: recorder, onSpacesTerminalLink: { routed.append($0) })

        coordinator.openLink("spaces://terminal/session-1?device=device-9")

        #expect(routed == [SpacesTerminalDeepLink(sessionID: "session-1", deviceID: "device-9")])
        #expect(recorder.opens.isEmpty)
        #expect(banner.errorMessages.isEmpty)
        #expect(banner.noticeMessages.isEmpty)
    }

    @Test func localFileLinkResolvesRelativePathAndOpens() throws {
        let workingDirectory = try makeTempDirectory()
        let subdirectory = workingDirectory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        let file = subdirectory.appendingPathComponent("notes.txt")
        try "local contents".write(to: file, atomically: true, encoding: .utf8)

        let banner = RecordingBanner()
        let recorder = OpenRecorder()
        let coordinator = makeCoordinator(isLocalDevice: true, workingDirectory: workingDirectory.path, banner: banner, recorder: recorder)

        coordinator.openLink("nested/notes.txt")

        #expect(recorder.opens.count == 1)
        #expect(recorder.opens.first?.url.standardizedFileURL == file.standardizedFileURL)
        #expect(recorder.opens.first?.category == .text)
        #expect(banner.errorMessages.isEmpty)
    }

    @Test func localFileLinkForMissingFileShowsErrorAndDoesNotOpen() throws {
        let workingDirectory = try makeTempDirectory()
        let banner = RecordingBanner()
        let recorder = OpenRecorder()
        let coordinator = makeCoordinator(isLocalDevice: true, workingDirectory: workingDirectory.path, banner: banner, recorder: recorder)

        coordinator.openLink("nested/missing.txt")

        #expect(recorder.opens.isEmpty)
        #expect(banner.errorMessages.count == 1)
    }

    // MARK: - Remote fetch

    @Test func remoteFileLinkResolveFailureShowsError() async {
        let banner = RecordingBanner()
        let recorder = OpenRecorder()
        let sender = FakeLinkSender()
        sender.setResolve(TerminalServiceResponse(ok: false, message: "link expired"), forLink: "artifact.png")
        let coordinator = makeCoordinator(isLocalDevice: false, sender: sender, banner: banner, recorder: recorder)

        coordinator.openLink("artifact.png")
        await waitUntil { !banner.errorMessages.isEmpty }

        #expect(banner.errorMessages == ["link expired"])
        #expect(recorder.opens.isEmpty)
    }

    @Test func remoteFileLinkSuccessWritesCacheAndOpensWithCategory() async throws {
        let banner = RecordingBanner()
        let recorder = OpenRecorder()
        let sender = FakeLinkSender()
        let sessionID = "session-\(UUID().uuidString)"
        let deviceID = "remote-\(UUID().uuidString)"
        let payload = Data("hello remote artifact\n".utf8)
        let linkID = "link-\(UUID().uuidString)"
        sender.setResolve(
            TerminalServiceResponse(
                ok: true, message: "",
                terminalLinkMetadata: metadata(
                    id: linkID, displayName: "notes.txt", contentType: "text/plain", artifactKind: "text", byteCount: Int64(payload.count))),
            forLink: "report.txt")
        sender.setChunk(
            TerminalServiceTerminalLinkChunk(
                linkID: linkID, offset: 0, byteCount: payload.count, isFinal: true, base64Data: payload.base64EncodedString()), forLinkID: linkID)
        let coordinator = makeCoordinator(
            isLocalDevice: false, sender: sender, banner: banner, recorder: recorder, sessionID: sessionID, deviceID: deviceID)

        coordinator.openLink("report.txt")
        await waitUntil { !recorder.opens.isEmpty }

        #expect(banner.errorMessages.isEmpty)
        #expect(banner.dismissCount >= 1)
        #expect(recorder.opens.count == 1)
        #expect(recorder.opens.first?.category == .text)
        let openedURL = try #require(recorder.opens.first?.url)
        #expect(try Data(contentsOf: openedURL) == payload)
    }

    @Test func remoteFileLinkCacheHitSkipsChunkReads() async throws {
        let banner = RecordingBanner()
        let recorder = OpenRecorder()
        let sender = FakeLinkSender()
        let sessionID = "session-\(UUID().uuidString)"
        let deviceID = "remote-\(UUID().uuidString)"
        let payload = Data("cached body".utf8)
        let linkID = "link-\(UUID().uuidString)"
        sender.setResolve(
            TerminalServiceResponse(
                ok: true, message: "",
                terminalLinkMetadata: metadata(
                    id: linkID, displayName: "data.txt", contentType: "text/plain", artifactKind: "text", byteCount: Int64(payload.count))),
            forLink: "data.txt")
        sender.setChunk(
            TerminalServiceTerminalLinkChunk(
                linkID: linkID, offset: 0, byteCount: payload.count, isFinal: true, base64Data: payload.base64EncodedString()), forLinkID: linkID)
        let coordinator = makeCoordinator(
            isLocalDevice: false, sender: sender, banner: banner, recorder: recorder, sessionID: sessionID, deviceID: deviceID)

        coordinator.openLink("data.txt")
        await waitUntil { recorder.opens.count == 1 }
        #expect(sender.chunkCount(forLinkID: linkID) >= 1)

        sender.resetChunkCount(forLinkID: linkID)
        coordinator.openLink("data.txt")
        await waitUntil { recorder.opens.count == 2 }

        #expect(sender.chunkCount(forLinkID: linkID) == 0)
        #expect(banner.errorMessages.isEmpty)
    }

    @Test func duplicateRemoteClickKeepsCurrentCacheWhenCancelledFetchFinishesLate() async throws {
        let banner = RecordingBanner()
        let recorder = OpenRecorder()
        let sender = FakeLinkSender()
        let sessionID = "session-\(UUID().uuidString)"
        let deviceID = "remote-\(UUID().uuidString)"
        let payload = Data("current cache body".utf8)
        let linkID = "link-\(UUID().uuidString)"
        sender.setResolve(
            TerminalServiceResponse(
                ok: true, message: "",
                terminalLinkMetadata: metadata(
                    id: linkID, displayName: "data.txt", contentType: "text/plain", artifactKind: "text", byteCount: Int64(payload.count))),
            forLink: "data.txt")
        sender.setChunk(
            TerminalServiceTerminalLinkChunk(
                linkID: linkID, offset: 0, byteCount: payload.count, isFinal: true, base64Data: payload.base64EncodedString()), forLinkID: linkID)
        let gate = DispatchSemaphore(value: 0)
        sender.setChunkGate(gate, forLinkID: linkID)
        let coordinator = makeCoordinator(
            isLocalDevice: false, sender: sender, banner: banner, recorder: recorder, sessionID: sessionID, deviceID: deviceID)

        coordinator.openLink("data.txt")
        await waitUntil { sender.chunkCount(forLinkID: linkID) == 1 }

        coordinator.openLink("data.txt")
        await waitUntil { recorder.opens.count == 1 }
        let openedURL = try #require(recorder.opens.first?.url)
        #expect(FileManager.default.fileExists(atPath: openedURL.path))
        #expect(try Data(contentsOf: openedURL) == payload)

        gate.signal()
        try? await Task.sleep(for: .milliseconds(300))

        #expect(FileManager.default.fileExists(atPath: openedURL.path))
        #expect(try Data(contentsOf: openedURL) == payload)
        #expect(banner.errorMessages.isEmpty)
    }

    @Test func secondClickCancelsFirstFetchSoItNeverOpens() async throws {
        let banner = RecordingBanner()
        let recorder = OpenRecorder()
        let sender = FakeLinkSender()
        let sessionID = "session-\(UUID().uuidString)"
        let deviceID = "remote-\(UUID().uuidString)"

        let firstPayload = Data("FIRST".utf8)
        let firstLinkID = "first-\(UUID().uuidString)"
        let gate = DispatchSemaphore(value: 0)
        sender.setResolve(
            TerminalServiceResponse(
                ok: true, message: "",
                terminalLinkMetadata: metadata(
                    id: firstLinkID, displayName: "first.txt", contentType: "text/plain", artifactKind: "text", byteCount: Int64(firstPayload.count))),
            forLink: "first.txt")
        sender.setChunk(
            TerminalServiceTerminalLinkChunk(
                linkID: firstLinkID, offset: 0, byteCount: firstPayload.count, isFinal: true, base64Data: firstPayload.base64EncodedString()),
            forLinkID: firstLinkID)
        // The first fetch blocks inside its chunk read until the test releases the gate.
        sender.setChunkGate(gate, forLinkID: firstLinkID)

        let secondPayload = Data("SECOND".utf8)
        let secondLinkID = "second-\(UUID().uuidString)"
        sender.setResolve(
            TerminalServiceResponse(
                ok: true, message: "",
                terminalLinkMetadata: metadata(
                    id: secondLinkID, displayName: "second.txt", contentType: "text/plain", artifactKind: "text",
                    byteCount: Int64(secondPayload.count))), forLink: "second.txt")
        sender.setChunk(
            TerminalServiceTerminalLinkChunk(
                linkID: secondLinkID, offset: 0, byteCount: secondPayload.count, isFinal: true, base64Data: secondPayload.base64EncodedString()),
            forLinkID: secondLinkID)

        let coordinator = makeCoordinator(
            isLocalDevice: false, sender: sender, banner: banner, recorder: recorder, sessionID: sessionID, deviceID: deviceID)

        coordinator.openLink("first.txt")
        // Wait until the first fetch has entered its (blocked) chunk read.
        await waitUntil { sender.chunkCount(forLinkID: firstLinkID) >= 1 }

        coordinator.openLink("second.txt")
        await waitUntil { recorder.opens.contains { (try? Data(contentsOf: $0.url)) == secondPayload } }

        // Release the superseded first fetch and give it a settle window; it must not open anything.
        gate.signal()
        try? await Task.sleep(for: .milliseconds(300))

        let openedContents = recorder.opens.compactMap { try? Data(contentsOf: $0.url) }
        #expect(openedContents.contains(secondPayload))
        #expect(!openedContents.contains(firstPayload))
    }

    // MARK: - Utilities

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coordinator-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
