import XCTest
import spacesmobilecore
import spacesterminalcore

@testable import spacesmobilebridge

final class SpacesMobileBridgeProtocolTests: XCTestCase {
    func testRequestRoundTripsScrollModsThroughCodec() throws {
        let request = SpacesMobileBridgeRequest(
            command: "scroll", authToken: "SECRET", sessionID: "session-1", clientID: "ios-client", ownerEpoch: 3, scrollHorizontal: 1.5,
            scrollVertical: -2.5, scrollMods: 7)

        XCTAssertEqual(try SpacesMobileBridgeCodec.decodeRequest(SpacesMobileBridgeCodec.encodeRequest(request)), request)
    }

    func testLegacyScrollRequestDecodesWithoutScrollMods() throws {
        let payload = #"{"command":"scroll","sessionID":"session-1","clientID":"ios-client","scrollVertical":24}"#.data(using: .utf8)!
        let request = try SpacesMobileBridgeCodec.decodeRequest(payload)

        XCTAssertEqual(request.scrollVertical, 24)
        XCTAssertNil(request.scrollMods)
    }

    func testMutationRequestRoundTripsWorkspaceAndRuntimeFields() throws {
        let request = SpacesMobileBridgeRequest(
            command: "createWorkspace", authToken: "SECRET", projectID: "project-1", workspaceID: "workspace-1", workspaceTitle: "Feature",
            branch: "feature", targetBranch: "main", directoryName: "feature-dir", allowExistingBranchReuse: true, processKey: "api",
            processID: "process-1", processTemplateID: "template-1", agentName: "Codex", agentID: "agent-1", agentLauncherID: "launcher-1")

        XCTAssertEqual(try SpacesMobileBridgeCodec.decodeRequest(SpacesMobileBridgeCodec.encodeRequest(request)), request)
    }

    func testLegacyOverviewDecodesWithProjectAndRowDefaults() throws {
        let payload = """
            {
              "workspaces": [{
                "id": "workspace-1",
                "projectID": "project-1",
                "projectName": "Project",
                "title": "Main",
                "dir": "/repo",
                "isRunning": false,
                "isArchived": false,
                "isHidden": false,
                "isDefault": true,
                "sessionCount": 0
              }],
              "sessions": []
            }
            """.data(using: .utf8)!

        let overview = try JSONDecoder().decode(SpacesMobileOverviewPayload.self, from: payload)

        XCTAssertEqual(overview.projects, [])
        XCTAssertEqual(overview.workspaces.first?.processRows, [])
        XCTAssertEqual(overview.workspaces.first?.codingAgentRows, [])
        XCTAssertEqual(overview.workspaces.first?.terminalRows, [])
    }

    func testTerminalDaemonEndpointRoundTripsOnRuntimeRowsAndSessionSummary() throws {
        let endpoint = SpacesMobileTerminalDaemonEndpoint(
            host: "builder.example.com", port: 7443, authToken: "SECRET", certificateFingerprint: "SHA256:abcdef")
        let processRow = SpacesMobileWorkspaceProcessRow(
            id: "process-1", workspaceID: "workspace-1", name: "API", command: "npm run dev", processID: "runtime-1", sessionID: "session-1",
            runState: .running, canRun: false, canStop: true, canRestart: true, daemonEndpoint: endpoint)
        let agentRow = SpacesMobileWorkspaceCodingAgentRow(
            id: "agent-1", workspaceID: "workspace-1", name: "Codex", command: "codex", agentID: "agent-runtime-1", sessionID: "session-2",
            isConfigured: true, runState: .running, activityState: .spinning, canRun: false, canStop: true, canRestart: true, daemonEndpoint: endpoint
        )
        let terminalRow = SpacesMobileWorkspaceTerminalRow(
            id: "terminal-1", workspaceID: "workspace-1", title: "Shell", workingDirectory: "/repo", sessionID: "session-3", runState: .running,
            canOpenTerminal: true, canStop: true, daemonEndpoint: endpoint)
        let session = SpacesMobileTerminalSessionSummary(
            id: "session-1", title: "API", workingDirectory: "/repo", state: .running, backend: .ghosttyEmbedded, lifetimePolicy: .persistent,
            servicePID: 123, childPID: 456, workspaceID: "workspace-1", workspaceTitle: "Feature", projectID: "project-1", projectName: "Project",
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:01Z", isControlAvailable: true, isSubscriptionAvailable: true,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), daemonEndpoint: endpoint)
        let overview = SpacesMobileOverviewPayload(
            workspaces: [
                SpacesMobileWorkspaceSummary(
                    id: "workspace-1", projectID: "project-1", projectName: "Project", title: "Feature", branch: nil, targetBranch: nil, dir: "/repo",
                    isRunning: true, isArchived: false, isHidden: false, isDefault: false, sessionCount: 1, processRows: [processRow],
                    codingAgentRows: [agentRow], terminalRows: [terminalRow])
            ], sessions: [session])

        let decoded = try SpacesMobileBridgeCodec.decodeResponse(
            SpacesMobileBridgeCodec.encodeResponse(SpacesMobileBridgeResponse(ok: true, message: "ok", overview: overview)))

        XCTAssertEqual(decoded.overview?.workspaces.first?.processRows.first?.daemonEndpoint, endpoint)
        XCTAssertEqual(decoded.overview?.workspaces.first?.codingAgentRows.first?.daemonEndpoint, endpoint)
        XCTAssertEqual(decoded.overview?.workspaces.first?.terminalRows.first?.daemonEndpoint, endpoint)
        XCTAssertEqual(decoded.overview?.sessions.first?.daemonEndpoint, endpoint)
    }

    func testLegacyTerminalRowDecodesWithoutDaemonEndpoint() throws {
        let payload = """
            {
              "id": "terminal-1",
              "workspaceID": "workspace-1",
              "title": "Shell",
              "workingDirectory": "/repo",
              "sessionID": "session-1",
              "runState": "running",
              "canOpenTerminal": true,
              "canStop": true
            }
            """.data(using: .utf8)!

        let row = try JSONDecoder().decode(SpacesMobileWorkspaceTerminalRow.self, from: payload)

        XCTAssertNil(row.daemonEndpoint)
    }

    func testResponseRoundTripsMutationOutputsAndCreateOptions() throws {
        let options = SpacesMobileWorkspaceCreateOptions(
            projects: [SpacesMobileProjectSummary(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")],
            selectedProjectID: "project-1", branchOptions: ["main"])
        let response = SpacesMobileBridgeResponse(
            ok: true, message: "ok", workspaceCreateOptions: options, workspaceID: "workspace-1", sessionID: "session-1")

        XCTAssertEqual(try SpacesMobileBridgeCodec.decodeResponse(SpacesMobileBridgeCodec.encodeResponse(response)), response)
    }

    func testTerminalLinkRequestsAndResponsesRoundTrip() throws {
        let resolveRequest = SpacesMobileBridgeRequest(
            command: "resolveTerminalLink", authToken: "SECRET", sessionID: "session-1", terminalLink: "images/screenshot.png")
        let chunkRequest = SpacesMobileBridgeRequest(
            command: "readTerminalLinkChunk", authToken: "SECRET", sessionID: "session-1", terminalLinkID: "link-1", chunkOffset: 128,
            chunkLimit: 4096)

        XCTAssertEqual(try SpacesMobileBridgeCodec.decodeRequest(SpacesMobileBridgeCodec.encodeRequest(resolveRequest)), resolveRequest)
        XCTAssertEqual(try SpacesMobileBridgeCodec.decodeRequest(SpacesMobileBridgeCodec.encodeRequest(chunkRequest)), chunkRequest)

        let metadata = SpacesMobileTerminalLinkMetadata(
            id: "link-1", source: .localFile, originalLink: "images/screenshot.png", displayName: "screenshot.png", contentType: "image/png",
            mediaKind: .image, byteCount: 12, externalURL: nil)
        let chunk = SpacesMobileTerminalLinkChunk(
            linkID: "link-1", offset: 0, byteCount: 4, isFinal: false, base64Data: Data([1, 2, 3, 4]).base64EncodedString())
        let response = SpacesMobileBridgeResponse(ok: true, message: "ok", terminalLinkMetadata: metadata, terminalLinkChunk: chunk)

        XCTAssertEqual(try SpacesMobileBridgeCodec.decodeResponse(SpacesMobileBridgeCodec.encodeResponse(response)), response)
    }

    func testTerminalLinkClassifierRejectsAudioMediaTypes() {
        XCTAssertEqual(SpacesMobileTerminalLinkClassifier.mediaKind(contentType: nil, pathExtension: "mp4"), .video)
        XCTAssertEqual(SpacesMobileTerminalLinkClassifier.mediaKind(contentType: nil, pathExtension: "png"), .image)
        XCTAssertNil(SpacesMobileTerminalLinkClassifier.mediaKind(contentType: "audio/mpeg", pathExtension: nil))
        XCTAssertNil(SpacesMobileTerminalLinkClassifier.mediaKind(contentType: nil, pathExtension: "mp3"))
        XCTAssertNil(SpacesMobileTerminalLinkClassifier.mediaKind(contentType: "audio/wav", pathExtension: "wav"))
    }

    func testWorkspaceTerminalRowRoundTripsStopAvailability() throws {
        let row = SpacesMobileWorkspaceTerminalRow(
            id: "terminal-shell", workspaceID: "workspace-1", title: "shell", workingDirectory: "/repo", sessionID: "session-1", runState: .running,
            canOpenTerminal: true, canStop: true)
        let overview = SpacesMobileOverviewPayload(
            workspaces: [
                SpacesMobileWorkspaceSummary(
                    id: "workspace-1", projectID: "project-1", projectName: "Project", title: "Feature", branch: nil, targetBranch: nil, dir: "/repo",
                    isRunning: true, isArchived: false, isHidden: false, isDefault: false, sessionCount: 1, terminalRows: [row])
            ], sessions: [])

        let decoded = try SpacesMobileBridgeCodec.decodeResponse(
            SpacesMobileBridgeCodec.encodeResponse(SpacesMobileBridgeResponse(ok: true, message: "ok", overview: overview)))

        XCTAssertEqual(decoded.overview?.workspaces.first?.terminalRows.first?.canStop, true)
    }

    func testTerminalLinkResolverResolvesRelativeAndHomeImageFiles() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let relativeImage = root.appendingPathComponent("image.png")
        let homeImage = root.appendingPathComponent("home-image.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: relativeImage)
        try Data([0x89, 0x50, 0x4E, 0x47, 0x02]).write(to: homeImage)

        let relativeMetadata = try SpacesMobileTerminalLinkResolver.resolve(
            sessionID: "session-1", link: "image.png", workingDirectory: root.path, workspaceRoots: [root.path], homeDirectory: root.path)
        let homeMetadata = try SpacesMobileTerminalLinkResolver.resolve(
            sessionID: "session-1", link: "~/home-image.png", workingDirectory: nil, workspaceRoots: [], homeDirectory: root.path)

        XCTAssertEqual(relativeMetadata.source, .localFile)
        XCTAssertEqual(relativeMetadata.displayName, "image.png")
        XCTAssertEqual(relativeMetadata.contentType, "image/png")
        XCTAssertEqual(relativeMetadata.mediaKind, .image)
        XCTAssertEqual(relativeMetadata.byteCount, 4)
        XCTAssertEqual(homeMetadata.displayName, "home-image.png")
        XCTAssertEqual(homeMetadata.byteCount, 5)
    }

    func testTerminalLinkResolverAllowsTmpImagePathsAfterSymlinkResolution() throws {
        let tmpImage = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmpImage) }
        let payload = Data([0x89, 0x50, 0x4E, 0x47, 0x01])
        try payload.write(to: tmpImage)

        let metadata = try SpacesMobileTerminalLinkResolver.resolve(sessionID: "session-1", link: tmpImage.path, workingDirectory: nil)
        let chunk = try SpacesMobileTerminalLinkResolver.readChunk(sessionID: "session-1", linkID: metadata.id, offset: 0, limit: 32)

        XCTAssertEqual(metadata.source, .localFile)
        XCTAssertEqual(metadata.displayName, tmpImage.lastPathComponent)
        XCTAssertEqual(metadata.mediaKind, .image)
        XCTAssertEqual(Data(base64Encoded: chunk.base64Data), payload)
        XCTAssertTrue(chunk.isFinal)
    }

    func testTerminalLinkResolverReadsLocalMediaFileWithSpaces() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("Screen Recording 2026-03-20 at 11.17.57 AM.mov")
        let payload = Data([0, 0, 0, 20, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74, 0x20, 0x20, 1, 2, 3, 4])
        try payload.write(to: movie)

        let metadata = try SpacesMobileTerminalLinkResolver.resolve(
            sessionID: "session-1", link: movie.path, workingDirectory: nil, workspaceRoots: [root.path], homeDirectory: root.path)
        let chunk = try SpacesMobileTerminalLinkResolver.readChunk(
            sessionID: "session-1", linkID: metadata.id, offset: 0, limit: 32, workspaceRoots: [root.path], homeDirectory: root.path)

        XCTAssertEqual(metadata.source, .localFile)
        XCTAssertEqual(metadata.originalLink, movie.path)
        XCTAssertEqual(metadata.displayName, "Screen Recording 2026-03-20 at 11.17.57 AM.mov")
        XCTAssertEqual(metadata.contentType, "video/quicktime")
        XCTAssertEqual(metadata.mediaKind, .video)
        XCTAssertEqual(metadata.byteCount, Int64(payload.count))
        XCTAssertEqual(Data(base64Encoded: chunk.base64Data), payload)
        XCTAssertTrue(chunk.isFinal)
    }

    func testTerminalLinkResolverReadsLocalMediaFileWithMacNoBreakSpace() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let movieName = "Screen Recording 2026-05-07 at 10.11.01\u{202F}AM.mov"
        let movie = root.appendingPathComponent(movieName)
        let payload = Data([0, 0, 0, 20, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74, 0x20, 0x20, 1, 2, 3, 4])
        try payload.write(to: movie)

        let metadata = try SpacesMobileTerminalLinkResolver.resolve(
            sessionID: "session-1", link: movie.path, workingDirectory: nil, workspaceRoots: [root.path], homeDirectory: root.path)
        let chunk = try SpacesMobileTerminalLinkResolver.readChunk(
            sessionID: "session-1", linkID: metadata.id, offset: 0, limit: 32, workspaceRoots: [root.path], homeDirectory: root.path)

        XCTAssertEqual(metadata.source, .localFile)
        XCTAssertEqual(metadata.originalLink, movie.path)
        XCTAssertEqual(metadata.displayName, movieName)
        XCTAssertEqual(metadata.contentType, "video/quicktime")
        XCTAssertEqual(metadata.mediaKind, .video)
        XCTAssertEqual(metadata.byteCount, Int64(payload.count))
        XCTAssertEqual(Data(base64Encoded: chunk.base64Data), payload)
        XCTAssertTrue(chunk.isFinal)
    }

    func testTerminalLinkResolverRejectsRemoteFileURLHosts() throws {
        let tmpImage = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmpImage) }
        try Data([0x89, 0x50, 0x4E, 0x47, 0x01]).write(to: tmpImage)

        let localhostMetadata = try SpacesMobileTerminalLinkResolver.resolve(
            sessionID: "session-1", link: "file://localhost\(tmpImage.path)", workingDirectory: nil)
        XCTAssertEqual(localhostMetadata.source, .localFile)
        XCTAssertEqual(localhostMetadata.displayName, tmpImage.lastPathComponent)

        XCTAssertThrowsError(
            try SpacesMobileTerminalLinkResolver.resolve(sessionID: "session-1", link: "file://build-host\(tmpImage.path)", workingDirectory: nil)
        ) { error in XCTAssertEqual(error as? SpacesMobileTerminalLinkResolverError, .unsupportedFileURLHost("build-host")) }
    }

    func testTerminalLinkResolverClassifiesExternalURLsWithoutTransfer() throws {
        let image = try SpacesMobileTerminalLinkResolver.resolve(
            sessionID: "session-1", link: "https://example.com/screenshot.png", workingDirectory: nil)
        let cleartextImage = try SpacesMobileTerminalLinkResolver.resolve(
            sessionID: "session-1", link: "http://example.com/screenshot.png", workingDirectory: nil)
        let audio = try SpacesMobileTerminalLinkResolver.resolve(sessionID: "session-1", link: "https://example.com/sound.mp3", workingDirectory: nil)
        let page = try SpacesMobileTerminalLinkResolver.resolve(sessionID: "session-1", link: "https://example.com/docs", workingDirectory: nil)

        XCTAssertEqual(image.source, .externalURL)
        XCTAssertEqual(image.mediaKind, .image)
        XCTAssertEqual(image.contentType, "image/png")
        XCTAssertEqual(image.externalURL, "https://example.com/screenshot.png")
        XCTAssertEqual(cleartextImage.source, .externalURL)
        XCTAssertNil(cleartextImage.contentType)
        XCTAssertNil(cleartextImage.mediaKind)
        XCTAssertEqual(cleartextImage.externalURL, "http://example.com/screenshot.png")
        XCTAssertEqual(audio.source, .externalURL)
        XCTAssertEqual(audio.contentType, "audio/mpeg")
        XCTAssertNil(audio.mediaKind)
        XCTAssertEqual(page.source, .externalURL)
        XCTAssertNil(page.mediaKind)
    }

    func testTerminalLinkResolverRejectsBlockedAndNonMediaPaths() throws {
        XCTAssertThrowsError(
            try SpacesMobileTerminalLinkResolver.resolve(sessionID: "session-1", link: "/System/Library/CoreServices", workingDirectory: nil)
        ) { error in XCTAssertEqual(error as? SpacesMobileTerminalLinkResolverError, .blockedPath("/System/Library/CoreServices")) }

        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blockedSymlink = root.appendingPathComponent("system-link.png")
        try FileManager.default.createSymbolicLink(at: blockedSymlink, withDestinationURL: URL(fileURLWithPath: "/System"))
        let textFile = root.appendingPathComponent("notes.txt")
        let audioFile = root.appendingPathComponent("sound.mp3")
        try Data("not media".utf8).write(to: textFile)
        try Data([0x49, 0x44, 0x33]).write(to: audioFile)

        XCTAssertThrowsError(
            try SpacesMobileTerminalLinkResolver.resolve(
                sessionID: "session-1", link: blockedSymlink.path, workingDirectory: nil, workspaceRoots: [root.path], homeDirectory: root.path)
        ) { error in XCTAssertEqual(error as? SpacesMobileTerminalLinkResolverError, .blockedPath("/System")) }

        XCTAssertThrowsError(
            try SpacesMobileTerminalLinkResolver.resolve(
                sessionID: "session-1", link: textFile.path, workingDirectory: nil, workspaceRoots: [root.path], homeDirectory: root.path)
        ) { error in XCTAssertEqual(error as? SpacesMobileTerminalLinkResolverError, .unsupportedMedia) }

        XCTAssertThrowsError(
            try SpacesMobileTerminalLinkResolver.resolve(
                sessionID: "session-1", link: audioFile.path, workingDirectory: nil, workspaceRoots: [root.path], homeDirectory: root.path)
        ) { error in XCTAssertEqual(error as? SpacesMobileTerminalLinkResolverError, .unsupportedMedia) }
    }

    func testTerminalLinkResolverReadsLocalMediaInChunksAndChecksSession() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("chunked.png")
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4, 5])
        try bytes.write(to: image)
        let metadata = try SpacesMobileTerminalLinkResolver.resolve(
            sessionID: "session-1", link: image.path, workingDirectory: nil, workspaceRoots: [root.path], homeDirectory: root.path)

        let first = try SpacesMobileTerminalLinkResolver.readChunk(
            sessionID: "session-1", linkID: metadata.id, offset: 0, limit: 4, workspaceRoots: [root.path], homeDirectory: root.path)
        let second = try SpacesMobileTerminalLinkResolver.readChunk(
            sessionID: "session-1", linkID: metadata.id, offset: 4, limit: 20, workspaceRoots: [root.path], homeDirectory: root.path)

        XCTAssertEqual(Data(base64Encoded: first.base64Data), bytes.prefix(4))
        XCTAssertFalse(first.isFinal)
        XCTAssertEqual(Data(base64Encoded: second.base64Data), bytes.dropFirst(4))
        XCTAssertTrue(second.isFinal)
        XCTAssertThrowsError(
            try SpacesMobileTerminalLinkResolver.readChunk(
                sessionID: "other-session", linkID: metadata.id, offset: 0, limit: 4, workspaceRoots: [root.path], homeDirectory: root.path)
        ) { error in XCTAssertEqual(error as? SpacesMobileTerminalLinkResolverError, .sessionMismatch) }
    }

}
