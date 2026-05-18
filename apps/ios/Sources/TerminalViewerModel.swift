import Foundation
import Observation
import UIKit
import spacesmobilecore
import spacesterminalcore

@MainActor @Observable final class TerminalViewerModel {
    let session: SpacesMobileTerminalSessionSummary
    let settings: SpacesMobileConnectionSettings

    var latestState: GhosttyRemoteSessionStatePayload?
    var pendingLine = ""
    var isConnecting = false
    var isBusy = false
    var errorMessage: String?

    private let bridgeClient: SpacesMobileBridgeClient
    private let remoteClient: TerminalClient
    private var streamHandle: SpacesMobileBridgeStreamHandle?
    private var isStopping = false

    init(session: SpacesMobileTerminalSessionSummary, settings: SpacesMobileConnectionSettings) {
        self.session = session
        self.settings = settings
        bridgeClient = SpacesMobileBridgeClient(settings: settings)
        remoteClient = TerminalClient(
            kind: .remoteViewer,
            identity: TerminalClientIdentity(
                label: UIDevice.current.name,
                hostName: nil,
                deviceName: UIDevice.current.name,
                networkAddress: settings.trimmedHost
            ),
            connectedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    var title: String { latestState?.title ?? session.title }
    var workingDirectory: String { latestState?.workingDirectory ?? session.workingDirectory }
    var visibleText: String { latestState?.snapshotText ?? "Waiting for terminal state…" }
    var attachmentSnapshot: TerminalSessionAttachmentSnapshot { latestState?.attachmentSnapshot ?? session.attachmentSnapshot }
    var isOwner: Bool {
        attachmentSnapshot.attachments.first(where: { $0.mode == .owner && $0.detachedAt == nil })?.clientID == remoteClient.id
    }
    var ownerLabel: String {
        let ownerClientID = attachmentSnapshot.attachments.first(where: { $0.mode == .owner && $0.detachedAt == nil })?.clientID
        return attachmentSnapshot.clients.first(where: { $0.id == ownerClientID })?.identity.label ?? "No owner"
    }

    func start() {
        guard streamHandle == nil else { return }
        isStopping = false
        isConnecting = true
        Task {
            do {
                try await bridgeClient.attach(sessionID: session.id, client: remoteClient, mode: .viewer)
                let handle = try bridgeClient.subscribe(sessionID: session.id, clientID: remoteClient.id) { [weak self] payload in
                    guard let self else { return }
                    latestState = payload
                    errorMessage = nil
                    isConnecting = false
                } onDisconnect: { [weak self] error in
                    guard let self else { return }
                    streamHandle = nil
                    isConnecting = false
                    if !isStopping, let error { errorMessage = error.localizedDescription }
                }
                streamHandle = handle
            } catch {
                isConnecting = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func stop() {
        isStopping = true
        streamHandle?.cancel()
        streamHandle = nil
        Task { try? await bridgeClient.detach(sessionID: session.id, clientID: remoteClient.id) }
    }

    func takeOver() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await bridgeClient.takeOver(sessionID: session.id, clientID: remoteClient.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendLine() async {
        guard isOwner else { return }
        let line = pendingLine
        guard !line.isEmpty else { return }
        pendingLine = ""
        await send(request: { [self] in
            try await bridgeClient.sendLine(sessionID: session.id, clientID: remoteClient.id, text: line)
        })
    }

    func sendKey(_ key: String) async {
        guard isOwner else { return }
        await send(request: { [self] in
            try await bridgeClient.sendKey(sessionID: session.id, clientID: remoteClient.id, key: key)
        })
    }

    private func send(request: @escaping () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await request()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
