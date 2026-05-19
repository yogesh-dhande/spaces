import Foundation
import Observation
import UIKit
import spacesmobilecore
import spacesterminalcore

@MainActor @Observable final class TerminalViewerModel {
    let session: SpacesMobileTerminalSessionSummary
    let settings: SpacesMobileConnectionSettings

    var latestState: GhosttyRemoteSessionStatePayload?
    var isConnecting = false
    var isBusy = false
    var isSessionUnavailable = false
    var errorMessage: String?

    private let bridgeClient: SpacesMobileBridgeClient
    private let remoteClient: TerminalClient
    private var streamHandle: SpacesMobileBridgeStreamHandle?
    private var reconnectTask: Task<Void, Never>?
    private var bufferedInputText = ""
    private var bufferedInputFlushTask: Task<Void, Never>?
    private var pendingInputSendTask: Task<Void, Never>?
    private var pendingResizeTask: Task<Void, Never>?
    private var viewportSize: (columns: Int, rows: Int)?
    private var lastSentResize: (columns: Int, rows: Int)?
    private var isStopping = false

    private static let inputBatchDelay: Duration = .milliseconds(35)
    private static let inputRequestTimeout: Duration = .seconds(6)
    private static let resizeDebounceDelay: Duration = .milliseconds(120)

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
    var snapshot: GhosttyTerminalSnapshot? { latestState?.snapshot }
    var visibleText: String {
        if let snapshotText = latestState?.snapshotText {
            return snapshotText
        }
        if isSessionUnavailable {
            return "This terminal session is no longer available.\nReturn to Terminals to open the current live session."
        }
        return "Waiting for terminal state…"
    }
    var attachmentSnapshot: TerminalSessionAttachmentSnapshot { latestState?.attachmentSnapshot ?? session.attachmentSnapshot }
    var isOwner: Bool {
        attachmentSnapshot.attachments.first(where: { $0.mode == .owner && $0.detachedAt == nil })?.clientID == remoteClient.id
    }
    var ownerLabel: String {
        let ownerClientID = attachmentSnapshot.attachments.first(where: { $0.mode == .owner && $0.detachedAt == nil })?.clientID
        return attachmentSnapshot.clients.first(where: { $0.id == ownerClientID })?.identity.label ?? "No owner"
    }

    func start() {
        guard streamHandle == nil, reconnectTask == nil else { return }
        isStopping = false
        isSessionUnavailable = false
        scheduleReconnect(after: .zero)
    }

    func stop() {
        isStopping = true
        reconnectTask?.cancel()
        reconnectTask = nil
        bufferedInputFlushTask?.cancel()
        bufferedInputFlushTask = nil
        pendingInputSendTask?.cancel()
        pendingInputSendTask = nil
        pendingResizeTask?.cancel()
        pendingResizeTask = nil
        bufferedInputText = ""
        viewportSize = nil
        lastSentResize = nil
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
            scheduleResizeIfNeeded(force: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateViewportSize(columns: Int, rows: Int) {
        let resolved = (columns: max(columns, 1), rows: max(rows, 1))
        guard viewportSize?.columns != resolved.columns || viewportSize?.rows != resolved.rows else { return }
        viewportSize = resolved
        scheduleResizeIfNeeded(force: false)
    }

    func sendText(_ text: String, appendNewline: Bool = false) async {
        guard isOwner else { return }
        guard !text.isEmpty else { return }
        if appendNewline {
            bufferInputText(text)
            flushBufferedInputText()
            await sendKey("enter")
            return
        }
        bufferInputText(text)
    }

    func sendKey(_ key: String) async {
        guard isOwner else { return }
        flushBufferedInputText()
        enqueueInputSend { [bridgeClient, sessionID = session.id, clientID = remoteClient.id] in
            try await Self.performInputRequest {
                try await bridgeClient.sendKey(
                    sessionID: sessionID,
                    clientID: clientID,
                    key: key,
                    timeout: Self.inputRequestTimeout
                )
            }
        }
    }

    private func send(request: @escaping () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await request()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func bufferInputText(_ text: String) {
        bufferedInputText.append(text)
        bufferedInputFlushTask?.cancel()
        bufferedInputFlushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.inputBatchDelay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.flushBufferedInputTextFromTask()
            }
        }
    }

    private func flushBufferedInputTextFromTask() {
        guard !bufferedInputText.isEmpty else { return }
        flushBufferedInputText()
    }

    private func flushBufferedInputText() {
        bufferedInputFlushTask?.cancel()
        bufferedInputFlushTask = nil
        let text = bufferedInputText
        bufferedInputText.removeAll(keepingCapacity: true)
        guard !text.isEmpty else { return }
        enqueueInputSend { [bridgeClient, sessionID = session.id, clientID = remoteClient.id] in
            try await Self.performInputRequest {
                try await bridgeClient.sendText(
                    sessionID: sessionID,
                    clientID: clientID,
                    text: text,
                    appendNewline: false,
                    timeout: Self.inputRequestTimeout
                )
            }
        }
    }

    private func enqueueInputSend(_ request: @escaping @Sendable () async throws -> Void) {
        let previousTask = pendingInputSendTask
        pendingInputSendTask = Task { [weak self] in
            _ = await previousTask?.result
            guard let self, !Task.isCancelled else { return }
            do {
                try await request()
            } catch {
                await MainActor.run {
                    self.handleInputSendError(error)
                }
            }
        }
    }

    private func handleInputSendError(_ error: Error) {
        guard !Self.isTransientInputTransportError(error) else { return }
        errorMessage = error.localizedDescription
    }

    private func scheduleReconnect(after delay: Duration) {
        guard !isStopping else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.connect()
        }
    }

    private func connect() async {
        guard !isStopping else {
            reconnectTask = nil
            return
        }

        isConnecting = true
        do {
            try await bridgeClient.attach(sessionID: session.id, client: remoteClient, mode: .viewer)
            if let initialState = try? await bridgeClient.fetchState(sessionID: session.id) {
                latestState = initialState
                isSessionUnavailable = false
                errorMessage = nil
                NSLog(
                    "[TerminalViewer] initial state cols=%ld rows=%ld textLength=%ld",
                    initialState.snapshot?.columns ?? -1,
                    initialState.snapshot?.rows ?? -1,
                    initialState.snapshotText?.count ?? 0
                )
            }
            let handle = try bridgeClient.subscribe(sessionID: session.id, clientID: remoteClient.id) { [weak self] payload in
                guard let self else { return }
                latestState = payload
                isSessionUnavailable = false
                errorMessage = nil
                isConnecting = false
                scheduleResizeIfNeeded(force: false)
                NSLog(
                    "[TerminalViewer] stream state cols=%ld rows=%ld textLength=%ld",
                    payload.snapshot?.columns ?? -1,
                    payload.snapshot?.rows ?? -1,
                    payload.snapshotText?.count ?? 0
                )
            } onDisconnect: { [weak self] error in
                Task { @MainActor [weak self] in
                    await self?.handleDisconnect(error)
                }
            }
            streamHandle = handle
            errorMessage = nil
            isConnecting = false
            reconnectTask = nil
        } catch {
            reconnectTask = nil
            isConnecting = false
            handleConnectError(error)
        }
    }

    private func handleDisconnect(_ error: Error?) async {
        streamHandle = nil
        isConnecting = false
        if isStopping { return }
        if let error {
            if let unavailableMessage = unavailableMessage(for: error) {
                isSessionUnavailable = true
                errorMessage = unavailableMessage
                return
            }
            errorMessage = error.localizedDescription
        }
        scheduleReconnect(after: .seconds(1))
    }

    private func handleConnectError(_ error: Error) {
        if let unavailableMessage = unavailableMessage(for: error) {
            isSessionUnavailable = true
            errorMessage = unavailableMessage
            return
        }
        errorMessage = error.localizedDescription
        scheduleReconnect(after: .seconds(1))
    }

    private func unavailableMessage(for error: Error) -> String? {
        switch error {
        case SpacesMobileBridgeClientError.requestFailed(let message),
             SpacesMobileBridgeClientError.streamFailed(let message):
            guard message.localizedStandardContains("is not available") else { return nil }
            return "This terminal session ended. Return to Terminals to open the current live session."
        default:
            return nil
        }
    }

    private func scheduleResizeIfNeeded(force: Bool) {
        guard isOwner else { return }
        guard let viewportSize else { return }
        if !force, lastSentResize?.columns == viewportSize.columns, lastSentResize?.rows == viewportSize.rows { return }
        pendingResizeTask?.cancel()
        pendingResizeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.resizeDebounceDelay)
            guard !Task.isCancelled else { return }
            await self?.sendResizeIfNeeded(force: force)
        }
    }

    private func sendResizeIfNeeded(force: Bool) async {
        guard isOwner else { return }
        guard let viewportSize else { return }
        if !force, lastSentResize?.columns == viewportSize.columns, lastSentResize?.rows == viewportSize.rows { return }
        let bridgeClient = bridgeClient
        let sessionID = session.id
        let clientID = remoteClient.id
        let columns = viewportSize.columns
        let rows = viewportSize.rows
        do {
            try await Self.performInputRequest {
                try await bridgeClient.resize(
                    sessionID: sessionID,
                    clientID: clientID,
                    columns: columns,
                    rows: rows,
                    timeout: Self.inputRequestTimeout
                )
            }
            lastSentResize = viewportSize
        } catch {
            handleInputSendError(error)
        }
    }

    private static func performInputRequest(_ request: @escaping @Sendable () async throws -> Void) async throws {
        do {
            try await request()
        } catch {
            guard isTransientInputTransportError(error) else { throw error }
            try await Task.sleep(for: .milliseconds(120))
            try await request()
        }
    }

    private static func isTransientInputTransportError(_ error: Error) -> Bool {
        switch error {
        case SpacesMobileBridgeClientError.requestTimedOut:
            return true
        case SpacesMobileBridgeClientError.requestFailed(let message):
            return message.localizedStandardContains("cancelled")
                || message.localizedStandardContains("timed out")
                || message.localizedStandardContains("The operation couldn’t be completed. Operation timed out")
        default:
            return false
        }
    }
}
