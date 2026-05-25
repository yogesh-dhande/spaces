import Darwin
import Foundation
import Observation
import UIKit
import spacesmobilecore
import spacesterminalmobileghostty
import spacesterminalcore

private let terminalViewerTraceEnabled = ProcessInfo.processInfo.environment["SPACES_MOBILE_TERMINAL_TRACE"] == "1"

private func terminalViewerTrace(_ sessionID: String, _ message: @autoclosure () -> String) {
    guard terminalViewerTraceEnabled else { return }
    fputs("spaces-mobile-terminal-trace t=\(terminalViewerTraceSeconds()) ios-viewer session=\(sessionID) \(message())\n", stderr)
    fflush(stderr)
}

private func terminalViewerTraceSeconds() -> String { String(format: "%.3f", Date().timeIntervalSince1970) }

private enum TerminalViewerRenderMode: String {
    case status
    case ownerBootstrapping
    case ownerLive
    case ended
}

@MainActor @Observable final class TerminalViewerModel {
    let session: SpacesMobileTerminalSessionSummary
    let settings: SpacesMobileConnectionSettings
    private let onAuthenticationRequired: @MainActor @Sendable (String) -> Void

    var latestState: GhosttyRemoteSessionStatePayload?
    var isConnecting = false
    var isBusy = false
    var isSessionUnavailable = false
    var isSynchronizingOwnership = false {
        didSet {
            guard isSynchronizingOwnership != oldValue else { return }
            trace("ownership_sync active=\(isSynchronizingOwnership ? 1 : 0)")
        }
    }
    var isOwnershipSynchronizationScheduled = false {
        didSet {
            guard isOwnershipSynchronizationScheduled != oldValue else { return }
            trace("ownership_sync scheduled=\(isOwnershipSynchronizationScheduled ? 1 : 0)")
        }
    }
    var isInputSurfaceReady = false {
        didSet {
            guard isInputSurfaceReady != oldValue else { return }
            trace("input_surface_ready value=\(isInputSurfaceReady ? 1 : 0) accepts_input=\(acceptsInput ? 1 : 0) owner=\(isOwner ? 1 : 0)")
        }
    }
    var errorMessage: String? {
        didSet {
            guard errorMessage != oldValue else { return }
            trace("error_message value=\(sanitizedTraceDetail(errorMessage ?? "nil"))")
        }
    }

    private let bridgeClient: SpacesMobileBridgeClient
    private var commandChannel: SpacesMobileBridgeCommandChannel
    private let remoteClient: TerminalClient
    private var e2eConfig: SpacesMobileE2EConfig { .shared }
    private var streamHandle: SpacesMobileBridgeStreamHandle?
    private var reconnectTask: Task<Void, Never>?
    private var bufferedInputText = ""
    private var bufferedInputFlushTask: Task<Void, Never>?
    private var pendingInputSendTask: Task<Void, Never>?
    private var ownershipSynchronizationTask: Task<Void, Never>?
    private var historySeedTask: Task<Void, Never>?
    private var viewportSize: (columns: Int, rows: Int)?
    private var lastSentResizeSize: (columns: Int, rows: Int)?
    private var needsOwnershipSynchronizationAfterCurrentRun = false
    private var isAwaitingTakeoverConfirmation = false {
        didSet {
            guard isAwaitingTakeoverConfirmation != oldValue else { return }
            trace("awaiting_takeover_confirmation value=\(isAwaitingTakeoverConfirmation ? 1 : 0)")
        }
    }
    private var isStopping = false
    private var hasAttachedToSession = false
    private var hasAttemptedAutomaticTakeover = false
    private var hasConfirmedOwnerInputReadiness = false
    private var ownerRecoveryGraceDeadline: Date?
    private var ownerRenderEpochState: GhosttyRemoteTerminalOwnerEpoch?
    private var requestedHistorySeedEpochID: String?
    private var reportedOwnerReadyEpochID: String?

    private static let inputBatchDelay: Duration = .milliseconds(35)
    private static let inputRequestTimeout: Duration = .seconds(6)
    private static let ownerRecoveryGraceInterval: TimeInterval = 2
    private static let silentReconnectDelay: Duration = .milliseconds(150)
    private static let viewportSyncWaitStep: Duration = .milliseconds(50)
    private static let viewportSyncWaitIterations = 8
    private static let ownershipSyncDebounce: Duration = .milliseconds(120)
    private static let postResizeStateSettleStep: Duration = .milliseconds(50)
    private static let postResizeStateSettleIterations = 6

    init(
        session: SpacesMobileTerminalSessionSummary,
        settings: SpacesMobileConnectionSettings,
        onAuthenticationRequired: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.session = session
        self.settings = settings
        self.onAuthenticationRequired = onAuthenticationRequired
        bridgeClient = SpacesMobileBridgeClient(settings: settings)
        commandChannel = bridgeClient.makeCommandChannel()
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
    var renderMode: String { renderModeValue.rawValue }
    var ownerRenderEpoch: GhosttyRemoteTerminalOwnerEpoch? { ownerRenderEpochState }
    var endedRender: GhosttyRemoteTerminalEndedRender? {
        guard shouldRenderEndedTerminalSurface, let snapshot = latestState?.snapshot else { return nil }
        return GhosttyRemoteTerminalEndedRender(id: endedRenderID(for: snapshot), snapshot: snapshot)
    }
    var latestScreenStateRevision: UInt64? { latestState?.screenStateRevision }
    var snapshotText: String? { latestState?.snapshotText ?? latestState?.snapshot.map(GhosttyTerminalSnapshotLayout.plainText) }
    var transcriptTail: String? { latestState?.transcriptTail }
    var replayStateKey: String {
        if let ownerRenderEpochState {
            return
                "owner|\(ownerRenderEpochState.id)|history=\(ownerRenderEpochState.historySeed?.id ?? "nil")|pending_count=\(ownerRenderEpochState.pendingOutputs.count)|pending_last=\(ownerRenderEpochState.pendingOutputs.last?.id ?? "nil")"
        }
        if let endedRender { return "ended|\(endedRender.id)" }
        return "status"
    }
    var showsTerminalSurface: Bool { isOwner || ownerRenderEpochState != nil || endedRender != nil }
    var shouldPresentLiveSurface: Bool { showsTerminalSurface }
    var visibleText: String {
        if shouldRenderEndedTerminalSurface, let transcriptTail, !transcriptTail.isEmpty {
            return transcriptTail
        }
        if shouldRenderEndedTerminalSurface, let snapshotText = latestState?.snapshotText {
            return snapshotText
        }
        if isSessionUnavailable {
            return "This terminal session is no longer available.\nReturn to Terminals to open the current live session."
        }
        if renderModeValue == .ended {
            return "This terminal session ended before a final render was available."
        }
        if renderModeValue == .ownerBootstrapping {
            return "Preparing terminal…"
        }
        if isTakingOver {
            return "Attempting takeover…"
        }
        let ownerLabel = activeOwnerDisplayLabel ?? "another client"
        return "Live terminal rendering is limited to the active owner.\nCurrent owner: \(ownerLabel)"
    }
    var attachmentSnapshot: TerminalSessionAttachmentSnapshot { latestState?.attachmentSnapshot ?? session.attachmentSnapshot }
    var isOwner: Bool { activeOwnerClientID == remoteClient.id }
    var isOwnershipSynchronizationPending: Bool { isOwnershipSynchronizationScheduled || isSynchronizingOwnership }
    var isTakingOver: Bool { !isOwner && (isAwaitingTakeoverConfirmation || isBusy || isOwnershipSynchronizationPending) }
    var acceptsInput: Bool { isOwner && !isBusy && !isConnecting && !isOwnershipSynchronizationPending && !isSessionUnavailable }
    var keepsTerminalInputSurfaceActive: Bool { isOwner && !isConnecting && !isSessionUnavailable }
    var isPreparingInput: Bool {
        isOwner && !isSessionUnavailable
            && (isBusy || isConnecting || isOwnershipSynchronizationPending || ownerRenderEpochState == nil || !isInputSurfaceReady)
    }
    var viewportColumns: Int? { viewportSize?.columns }
    var viewportRows: Int? { viewportSize?.rows }
    var lastSentResizeColumns: Int? { lastSentResizeSize?.columns }
    var lastSentResizeRows: Int? { lastSentResizeSize?.rows }
    var runtimeColumns: Int? { latestState?.runtimeState?.columns }
    var runtimeRows: Int? { latestState?.runtimeState?.rows }
    var snapshotColumns: Int? { latestState?.snapshot?.columns }
    var snapshotRows: Int? { latestState?.snapshot?.rows }

    func start() {
        guard streamHandle == nil, reconnectTask == nil else { return }
        isStopping = false
        isSessionUnavailable = false
        hasAttemptedAutomaticTakeover = false
        trace("start")
        scheduleReconnect(after: .zero)
    }

    func stop() {
        trace("stop")
        isStopping = true
        isAwaitingTakeoverConfirmation = false
        hasAttachedToSession = false
        hasAttemptedAutomaticTakeover = false
        hasConfirmedOwnerInputReadiness = false
        isInputSurfaceReady = false
        reconnectTask?.cancel()
        reconnectTask = nil
        bufferedInputFlushTask?.cancel()
        bufferedInputFlushTask = nil
        pendingInputSendTask?.cancel()
        pendingInputSendTask = nil
        ownershipSynchronizationTask?.cancel()
        ownershipSynchronizationTask = nil
        historySeedTask?.cancel()
        historySeedTask = nil
        bufferedInputText = ""
        viewportSize = nil
        lastSentResizeSize = nil
        needsOwnershipSynchronizationAfterCurrentRun = false
        ownerRenderEpochState = nil
        ownerRecoveryGraceDeadline = nil
        requestedHistorySeedEpochID = nil
        reportedOwnerReadyEpochID = nil
        isOwnershipSynchronizationScheduled = false
        isSynchronizingOwnership = false
        streamHandle?.cancel()
        streamHandle = nil
        let currentChannel = commandChannel
        Task {
            try? await bridgeClient.detach(sessionID: session.id, clientID: remoteClient.id)
            await currentChannel.close()
        }
    }

    private var renderModeValue: TerminalViewerRenderMode {
        if shouldRenderEndedTerminalSurface { return .ended }
        if isOwner {
            return hasConfirmedOwnerInputReadiness && ownerRenderEpochState != nil ? .ownerLive : .ownerBootstrapping
        }
        return .status
    }

    func takeOver() async {
        guard !isBusy else { return }
        hasAttemptedAutomaticTakeover = true
        isBusy = true
        defer { isBusy = false }
        trace("takeover_begin")
        do {
            try await bridgeClient.takeOver(
                sessionID: session.id,
                clientID: remoteClient.id,
                timeout: Self.inputRequestTimeout
            )
            replaceCommandChannel()
            isAwaitingTakeoverConfirmation = true
            hasConfirmedOwnerInputReadiness = false
            isInputSurfaceReady = false
            errorMessage = nil
            trace("takeover_success")
        } catch {
            isAwaitingTakeoverConfirmation = false
            if Self.isTransientReconnectError(error) {
                trace("takeover_transient_failure error=\(sanitizedTraceDetail(error.localizedDescription))")
                errorMessage = nil
                return
            }
            if handleAuthenticationFailure(error) { return }
            trace("takeover_failure error=\(sanitizedTraceDetail(error.localizedDescription))")
            errorMessage = error.localizedDescription
        }
    }

    func updateViewportSize(columns: Int, rows: Int) {
        let resolved = (columns: max(columns, 1), rows: max(rows, 1))
        guard viewportSize?.columns != resolved.columns || viewportSize?.rows != resolved.rows else { return }
        viewportSize = resolved
        trace(
            "viewport_update columns=\(resolved.columns) rows=\(resolved.rows) owner=\(isOwner ? 1 : 0) busy=\(isBusy ? 1 : 0) syncing=\(isSynchronizingOwnership ? 1 : 0) sync_scheduled=\(isOwnershipSynchronizationScheduled ? 1 : 0)"
        )
        if isOwner && !isBusy {
            if isSynchronizingOwnership {
                needsOwnershipSynchronizationAfterCurrentRun = true
                trace("ownership_sync_reschedule_after_current")
            } else {
                scheduleOwnershipSynchronization()
            }
        }
    }

    func sendText(_ text: String, appendNewline: Bool = false) async {
        guard isOwner else { return }
        guard acceptsInput, hasConfirmedOwnerInputReadiness else { return }
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
        guard acceptsInput, hasConfirmedOwnerInputReadiness else { return }
        flushBufferedInputText()
        enqueueInputSend(kind: "send_key", detail: key) { [weak self, key] in
            guard let self else { return }
            try await self.performSendKeyRequest(key)
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
        enqueueInputSend(kind: "send_text", detail: text) { [weak self, text] in
            guard let self else { return }
            try await self.performSendTextRequest(text)
        }
    }

    private func performSendTextRequest(_ text: String) async throws {
        try await performRequestUsingInputChannel { [bridgeClient, sessionID = session.id, clientID = remoteClient.id] commandChannel in
            try await bridgeClient.sendText(
                sessionID: sessionID,
                clientID: clientID,
                text: text,
                appendNewline: false,
                timeout: Self.inputRequestTimeout,
                commandChannel: commandChannel
            )
        }
    }

    private func performSendKeyRequest(_ key: String) async throws {
        try await performRequestUsingInputChannel { [bridgeClient, sessionID = session.id, clientID = remoteClient.id] commandChannel in
            try await bridgeClient.sendKey(
                sessionID: sessionID,
                clientID: clientID,
                key: key,
                timeout: Self.inputRequestTimeout,
                commandChannel: commandChannel
            )
        }
    }

    private func performRequestUsingInputChannel(
        _ request: @escaping @Sendable (SpacesMobileBridgeCommandChannel) async throws -> Void
    ) async throws {
        do {
            try await request(commandChannel)
        } catch {
            guard Self.isTransientInputTransportError(error) else { throw error }
            replaceCommandChannel()
            try await Task.sleep(for: .milliseconds(120))
            try await request(commandChannel)
        }
    }

    private func enqueueInputSend(
        kind: String,
        detail: String,
        _ request: @escaping @Sendable () async throws -> Void
    ) {
        let previousTask = pendingInputSendTask
        pendingInputSendTask = Task { [weak self] in
            _ = await previousTask?.result
            guard let self, !Task.isCancelled else { return }
            do {
                await MainActor.run {
                    self.writeE2EEventIfNeeded(kind: "\(kind)_begin", detail: detail)
                }
                try await request()
                await MainActor.run {
                    if self.isOwner {
                        self.hasConfirmedOwnerInputReadiness = true
                        self.isInputSurfaceReady = true
                    }
                    self.writeE2EEventIfNeeded(kind: "\(kind)_success", detail: detail)
                }
            } catch {
                await MainActor.run {
                    self.writeE2EEventIfNeeded(kind: "\(kind)_failure", detail: "\(detail) :: \(error.localizedDescription)")
                    self.handleInputSendError(error)
                }
            }
        }
    }

    private func handleInputSendError(_ error: Error) {
        guard !Self.isTransientInputTransportError(error) else { return }
        if handleAuthenticationFailure(error) { return }
        errorMessage = error.localizedDescription
    }

    private func replaceCommandChannel() {
        let previousChannel = commandChannel
        commandChannel = bridgeClient.makeCommandChannel()
        trace("replace_command_channel")
        Task { await previousChannel.close() }
    }

    private func scheduleReconnect(after delay: Duration) {
        guard !isStopping else { return }
        trace("schedule_reconnect delay_ms=\(Self.traceDurationMilliseconds(delay)) silent=\(shouldReconnectSilently ? 1 : 0)")
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

        let reconnectSilently = shouldReconnectSilently
        trace("connect_begin silent=\(reconnectSilently ? 1 : 0) attach_before_subscribe=\(shouldAttachBeforeSubscribing ? 1 : 0)")
        if reconnectSilently {
            isConnecting = false
        } else {
            isConnecting = true
        }
        do {
            if shouldAttachBeforeSubscribing {
                try await bridgeClient.attach(
                    sessionID: session.id,
                    client: remoteClient,
                    mode: .viewer
                )
                hasAttachedToSession = true
                trace("connect_attach_success")
            }
            let handle = try bridgeClient.subscribe(sessionID: session.id, clientID: remoteClient.id) { [weak self] payload in
                guard let self else { return }
                applyLatestState(payload)
            } onDisconnect: { [weak self] error in
                Task { @MainActor [weak self] in
                    await self?.handleDisconnect(error)
                }
            }
            streamHandle = handle
            errorMessage = nil
            reconnectTask = nil
            trace("connect_subscribe_success")
        } catch {
            reconnectTask = nil
            isConnecting = false
            trace("connect_failure error=\(sanitizedTraceDetail(error.localizedDescription))")
            handleConnectError(error)
        }
    }

    @discardableResult
    private func refreshLatestState(
        timeout: Duration = .seconds(3),
        ignoreTransientTimeout: Bool = false,
        includeOutputHistory: Bool = false,
        applyToLatestState: Bool = true,
        reason: String = "state_refresh"
    ) async
        -> GhosttyRemoteSessionStatePayload?
    {
        trace(
            "fetch_state_begin timeout_ms=\(Self.traceDurationMilliseconds(timeout)) ignore_transient_timeout=\(ignoreTransientTimeout ? 1 : 0) include_output_history=\(includeOutputHistory ? 1 : 0) reason=\(reason)"
        )
        logPerformanceEvent(
            name: "explicit_state_refresh_begin",
            attributes: [
                "reason": reason,
                "include_output_history": includeOutputHistory ? "1" : "0",
            ]
        )
        let startedAt = Date()
        do {
            let fetchedState = try await bridgeClient.fetchState(
                sessionID: session.id,
                includeOutputHistory: includeOutputHistory,
                timeout: timeout
            )
            trace(
                "fetch_state_success reason=\(fetchedState.reason) runtime=\(traceSize(columns: fetchedState.runtimeState?.columns, rows: fetchedState.runtimeState?.rows)) snapshot=\(traceSize(columns: fetchedState.snapshot?.columns, rows: fetchedState.snapshot?.rows)) owner=\(traceOwnerID(fetchedState.attachmentSnapshot))"
            )
            logPerformanceEvent(
                name: "explicit_state_refresh_end",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                count: fetchedState.outputData?.count,
                attributes: [
                    "reason": reason,
                    "include_output_history": includeOutputHistory ? "1" : "0",
                    "snapshot": fetchedState.snapshot == nil ? "0" : "1",
                ]
            )
            if applyToLatestState { applyLatestState(fetchedState) }
            return fetchedState
        } catch {
            trace(
                "fetch_state_failure error=\(sanitizedTraceDetail(error.localizedDescription)) ignore_transient_timeout=\(ignoreTransientTimeout ? 1 : 0) reason=\(reason)"
            )
            logPerformanceEvent(
                name: "explicit_state_refresh_failure",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                attributes: [
                    "reason": reason,
                    "include_output_history": includeOutputHistory ? "1" : "0",
                ]
            )
            if ignoreTransientTimeout, Self.isTransientReconnectError(error) {
                errorMessage = nil
                return nil
            }
            if handleAuthenticationFailure(error) { return nil }
            if let unavailableMessage = unavailableMessage(for: error) {
                isSessionUnavailable = true
                errorMessage = unavailableMessage
                return nil
            }
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func handleDisconnect(_ error: Error?) async {
        let reconnectSilently = shouldReconnectSilently
        trace("disconnect error=\(sanitizedTraceDetail(error?.localizedDescription ?? "nil")) silent=\(reconnectSilently ? 1 : 0)")
        streamHandle = nil
        isConnecting = false
        if !reconnectSilently {
            isAwaitingTakeoverConfirmation = false
            hasConfirmedOwnerInputReadiness = false
            isInputSurfaceReady = false
        }
        if isStopping { return }
        if let error {
            if handleAuthenticationFailure(error) { return }
            if let unavailableMessage = unavailableMessage(for: error) {
                isSessionUnavailable = true
                errorMessage = unavailableMessage
                return
            }
            if Self.isTransientReconnectError(error), latestState != nil {
                errorMessage = nil
            } else {
                errorMessage = error.localizedDescription
            }
        }
        scheduleReconnect(after: reconnectSilently ? Self.silentReconnectDelay : .seconds(1))
    }

    private func handleConnectError(_ error: Error) {
        trace("connect_error error=\(sanitizedTraceDetail(error.localizedDescription)) silent=\(shouldReconnectSilently ? 1 : 0)")
        if handleAuthenticationFailure(error) { return }
        if let unavailableMessage = unavailableMessage(for: error) {
            isSessionUnavailable = true
            errorMessage = unavailableMessage
            return
        }
        if Self.isTransientReconnectError(error), latestState != nil {
            errorMessage = nil
        } else {
            errorMessage = error.localizedDescription
        }
        scheduleReconnect(after: shouldReconnectSilently ? Self.silentReconnectDelay : .seconds(1))
    }

    private var shouldReconnectSilently: Bool {
        latestState != nil && (isWithinOwnerRecoveryGracePeriod || isAwaitingTakeoverConfirmation || isOwner)
    }

    private var isEndedState: Bool {
        let state = latestState?.runtimeState?.state ?? session.state
        return state != .running && state != .starting
    }

    private var shouldRenderEndedTerminalSurface: Bool {
        guard isOwner == false, isEndedState else { return false }
        return latestState?.snapshot != nil
    }

    private var activeOwnerDisplayLabel: String? {
        guard let ownerAttachment = attachmentSnapshot.attachments.first(where: { $0.mode == .owner && $0.detachedAt == nil }) else { return nil }
        return attachmentSnapshot.clients.first(where: { $0.id == ownerAttachment.clientID })?.identity.deviceName
            ?? attachmentSnapshot.clients.first(where: { $0.id == ownerAttachment.clientID })?.identity.hostName
            ?? attachmentSnapshot.clients.first(where: { $0.id == ownerAttachment.clientID })?.identity.label
    }

    private func attemptAutomaticTakeoverIfNeeded() {
        guard !hasAttemptedAutomaticTakeover else { return }
        guard !isOwner else { return }
        guard !isSessionUnavailable else { return }
        let state = latestState?.runtimeState?.state ?? session.state
        guard state == .running else { return }
        hasAttemptedAutomaticTakeover = true
        trace("auto_takeover_begin")
        Task { [weak self] in
            await self?.takeOver()
        }
    }

    private var isWithinOwnerRecoveryGracePeriod: Bool {
        guard let ownerRecoveryGraceDeadline else { return false }
        return ownerRecoveryGraceDeadline.timeIntervalSinceNow > 0
    }

    private func beginOwnerRecoveryGracePeriod(now: Date = Date()) {
        ownerRecoveryGraceDeadline = now.addingTimeInterval(Self.ownerRecoveryGraceInterval)
    }

    private func scheduleOwnershipSynchronization() {
        guard isOwner else { return }
        guard !isBusy else { return }
        if isSynchronizingOwnership {
            needsOwnershipSynchronizationAfterCurrentRun = true
            trace("ownership_sync_reschedule_after_current")
            return
        }
        trace("schedule_ownership_sync viewport=\(traceSize(columns: viewportSize?.columns, rows: viewportSize?.rows)) runtime=\(traceSize(columns: latestState?.runtimeState?.columns, rows: latestState?.runtimeState?.rows))")
        startOwnershipSynchronization()
    }

    private func startOwnershipSynchronization() {
        guard isOwner else { return }
        isOwnershipSynchronizationScheduled = true
        ownershipSynchronizationTask?.cancel()
        ownershipSynchronizationTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: Self.ownershipSyncDebounce)
            guard !Task.isCancelled else { return }
            await self.runOwnershipSynchronization()
        }
    }

    private func runOwnershipSynchronization() async {
        var shouldScheduleFollowUp = false
        defer {
            isSynchronizingOwnership = false
            ownershipSynchronizationTask = nil
            isOwnershipSynchronizationScheduled = false
            if shouldScheduleFollowUp {
                needsOwnershipSynchronizationAfterCurrentRun = false
                scheduleOwnershipSynchronization()
            }
        }
        guard isOwner else { return }
        isSynchronizingOwnership = true
        errorMessage = nil
        let targetViewportSize = await awaitViewportSizeIfNeeded()
        logPerformanceEvent(
            name: "resize_reconciliation_begin",
            attributes: [
                "viewport_columns": String(targetViewportSize?.columns ?? 0),
                "viewport_rows": String(targetViewportSize?.rows ?? 0),
                "runtime_columns": String(latestState?.runtimeState?.columns ?? 0),
                "runtime_rows": String(latestState?.runtimeState?.rows ?? 0),
            ]
        )
        let startedAt = Date()
        trace("ownership_sync_begin viewport=\(traceSize(columns: targetViewportSize?.columns, rows: targetViewportSize?.rows)) runtime_before=\(traceSize(columns: latestState?.runtimeState?.columns, rows: latestState?.runtimeState?.rows))")
        await synchronizeOwnershipState(targetViewportSize: targetViewportSize)
        logPerformanceEvent(
            name: "resize_reconciliation_end",
            elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
            attributes: [
                "viewport_columns": String(targetViewportSize?.columns ?? 0),
                "viewport_rows": String(targetViewportSize?.rows ?? 0),
                "runtime_columns": String(latestState?.runtimeState?.columns ?? 0),
                "runtime_rows": String(latestState?.runtimeState?.rows ?? 0),
            ]
        )
        trace("ownership_sync_end runtime_after=\(traceSize(columns: latestState?.runtimeState?.columns, rows: latestState?.runtimeState?.rows)) owner=\(isOwner ? 1 : 0)")
        shouldScheduleFollowUp = shouldResynchronizeOwnership(afterTargeting: targetViewportSize)
    }

    private func shouldResynchronizeOwnership(afterTargeting targetViewportSize: (columns: Int, rows: Int)?) -> Bool {
        guard isOwner, !isBusy else { return false }
        if needsOwnershipSynchronizationAfterCurrentRun { return true }
        guard let targetViewportSize, let viewportSize else { return false }
        return targetViewportSize.columns != viewportSize.columns || targetViewportSize.rows != viewportSize.rows
    }

    private func awaitViewportSizeIfNeeded() async -> (columns: Int, rows: Int)? {
        if let viewportSize { return viewportSize }
        for _ in 0..<Self.viewportSyncWaitIterations {
            try? await Task.sleep(for: Self.viewportSyncWaitStep)
            guard isOwner else { return nil }
            if let viewportSize { return viewportSize }
        }
        return viewportSize
    }

    private func synchronizeOwnershipState(targetViewportSize: (columns: Int, rows: Int)?) async {
        let previousEmittedAt = latestState?.emittedAt
        let previousScreenRevision = latestState?.screenStateRevision
        let previousRuntimeSize = latestState.map { ($0.runtimeState?.columns, $0.runtimeState?.rows) }
        if let targetViewportSize {
            trace("ownership_resize_begin columns=\(targetViewportSize.columns) rows=\(targetViewportSize.rows)")
            do {
                lastSentResizeSize = targetViewportSize
                try await bridgeClient.resize(
                    sessionID: session.id,
                    clientID: remoteClient.id,
                    columns: targetViewportSize.columns,
                    rows: targetViewportSize.rows,
                    timeout: Self.inputRequestTimeout
                )
                trace("ownership_resize_success columns=\(targetViewportSize.columns) rows=\(targetViewportSize.rows)")
            } catch {
                trace("ownership_resize_failure columns=\(targetViewportSize.columns) rows=\(targetViewportSize.rows) error=\(sanitizedTraceDetail(error.localizedDescription))")
                if !Self.isTransientReconnectError(error) {
                    if handleAuthenticationFailure(error) { return }
                    errorMessage = error.localizedDescription
                }
            }
        }
        let streamedState = await awaitOwnerStateFromStream(
            targetViewportSize: targetViewportSize,
            previousEmittedAt: previousEmittedAt,
            previousScreenRevision: previousScreenRevision,
            previousRuntimeSize: previousRuntimeSize
        )
        guard isOwner else { return }
        if ownerRenderEpochState == nil {
            if streamedState != nil {
                trace("ownership_sync_using_streamed_state")
                beginOwnerRenderEpoch(from: streamedState)
                return
            }
            if hasUsableOwnerBootstrapState(latestState) {
                trace("ownership_sync_using_existing_state")
                beginOwnerRenderEpoch(from: latestState)
                return
            }
            let refreshedState = await refreshLatestState(
                timeout: Self.inputRequestTimeout,
                ignoreTransientTimeout: true,
                reason: "owner_bootstrap_refresh"
            )
            trace("ownership_sync_using_fetched_state snapshot=\(refreshedState?.snapshot == nil ? 0 : 1) output_bytes=\(refreshedState?.outputData?.count ?? 0)")
            beginOwnerRenderEpoch(from: refreshedState ?? latestState)
        }
    }

    private func awaitOwnerStateFromStream(
        targetViewportSize: (columns: Int, rows: Int)?,
        previousEmittedAt: String?,
        previousScreenRevision: UInt64?,
        previousRuntimeSize: (Int?, Int?)?
    ) async -> GhosttyRemoteSessionStatePayload? {
        guard targetViewportSize != nil else { return latestState }
        for _ in 0..<Self.postResizeStateSettleIterations {
            guard isOwner else { return nil }
            if let latestState,
                ownerStateLooksFresh(
                    latestState,
                    targetViewportSize: targetViewportSize,
                    previousEmittedAt: previousEmittedAt,
                    previousScreenRevision: previousScreenRevision,
                    previousRuntimeSize: previousRuntimeSize
                )
            {
                return latestState
            }
            try? await Task.sleep(for: Self.postResizeStateSettleStep)
        }
        return nil
    }

    private func ownerStateLooksFresh(
        _ payload: GhosttyRemoteSessionStatePayload,
        targetViewportSize: (columns: Int, rows: Int)?,
        previousEmittedAt: String?,
        previousScreenRevision: UInt64?,
        previousRuntimeSize: (Int?, Int?)?
    ) -> Bool {
        guard hasUsableOwnerBootstrapState(payload) else { return false }
        if let targetViewportSize {
            let runtimeColumns = payload.runtimeState?.columns
            let runtimeRows = payload.runtimeState?.rows
            let matchesTargetViewport = runtimeColumns == targetViewportSize.columns && runtimeRows == targetViewportSize.rows
            let runtimeChanged =
                runtimeColumns != previousRuntimeSize?.0 || runtimeRows != previousRuntimeSize?.1
            let emittedChanged = payload.emittedAt != previousEmittedAt
            let screenRevisionChanged = payload.screenStateRevision != previousScreenRevision
            return matchesTargetViewport && (runtimeChanged || emittedChanged || screenRevisionChanged)
        }
        return payload.emittedAt != previousEmittedAt || payload.screenStateRevision != previousScreenRevision
    }

    private func hasUsableOwnerBootstrapState(_ payload: GhosttyRemoteSessionStatePayload?) -> Bool {
        guard let payload else { return false }
        return payload.snapshot != nil
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

    private func handleAuthenticationFailure(_ error: Error) -> Bool {
        guard let recoveryMessage = SpacesMobileBridgeAuthentication.recoveryMessage(for: error) else { return false }
        isStopping = true
        isAwaitingTakeoverConfirmation = false
        reconnectTask?.cancel()
        reconnectTask = nil
        bufferedInputFlushTask?.cancel()
        bufferedInputFlushTask = nil
        pendingInputSendTask?.cancel()
        pendingInputSendTask = nil
        bufferedInputText = ""
        hasAttachedToSession = false
        hasConfirmedOwnerInputReadiness = false
        isInputSurfaceReady = false
        ownershipSynchronizationTask?.cancel()
        ownershipSynchronizationTask = nil
        historySeedTask?.cancel()
        historySeedTask = nil
        requestedHistorySeedEpochID = nil
        reportedOwnerReadyEpochID = nil
        needsOwnershipSynchronizationAfterCurrentRun = false
        isOwnershipSynchronizationScheduled = false
        isSynchronizingOwnership = false
        streamHandle?.cancel()
        streamHandle = nil
        errorMessage = nil
        onAuthenticationRequired(recoveryMessage)
        return true
    }

    private static func isTransientInputTransportError(_ error: Error) -> Bool {
        if let code = transientPOSIXErrorCode(error),
            code == Int(EAGAIN) || code == Int(EWOULDBLOCK) || code == Int(ETIMEDOUT) || code == Int(ECONNRESET)
                || code == Int(ECONNABORTED) || code == Int(EPIPE) || code == Int(ECONNREFUSED) || code == Int(EBADF)
                || code == Int(ENOTSOCK)
        {
            return true
        }
        switch error {
        case SpacesMobileBridgeClientError.requestTimedOut:
            return true
        case SpacesMobileBridgeClientError.requestFailed(let message):
            return message.localizedStandardContains("cancelled")
                || message.localizedStandardContains("timed out")
                || message.localizedStandardContains("The operation couldn’t be completed. Operation timed out")
                || message.localizedStandardContains("temporarily unavailable")
                || message.localizedStandardContains("bad file descriptor")
                || message.localizedStandardContains("socket operation on non-socket")
        default:
            return false
        }
    }

    private static func isTransientReconnectError(_ error: Error) -> Bool {
        if let code = transientPOSIXErrorCode(error),
            code == Int(EAGAIN) || code == Int(EWOULDBLOCK) || code == Int(ETIMEDOUT) || code == Int(ECONNRESET)
                || code == Int(ECONNABORTED) || code == Int(EPIPE) || code == Int(ECONNREFUSED)
        {
            return true
        }
        switch error {
        case SpacesMobileBridgeClientError.requestTimedOut:
            return true
        case SpacesMobileBridgeClientError.requestFailed(let message),
             SpacesMobileBridgeClientError.streamFailed(let message):
            return message.localizedStandardContains("cancelled")
                || message.localizedStandardContains("timed out")
                || message.localizedStandardContains("The operation couldn’t be completed. Operation timed out")
                || message.localizedStandardContains("temporarily unavailable")
        default:
            return false
        }
    }

    private static func transientPOSIXErrorCode(_ error: Error) -> Int? {
        let nsError = error as NSError
        guard nsError.domain == NSPOSIXErrorDomain else { return nil }
        return nsError.code
    }

    private var shouldAttachBeforeSubscribing: Bool {
        guard !hasAttachedToSession else { return false }
        guard let latestState else { return true }
        return !activeAttachmentExists(in: latestState.attachmentSnapshot)
    }

    private var activeOwnerClientID: String? {
        attachmentSnapshot.attachments.first(where: { $0.mode == .owner && $0.detachedAt == nil })?.clientID
    }

    private func activeAttachmentExists(in snapshot: TerminalSessionAttachmentSnapshot?) -> Bool {
        guard let snapshot else { return false }
        return snapshot.attachments.contains { attachment in
            attachment.clientID == remoteClient.id && attachment.detachedAt == nil
        }
    }

    private func payloadByClearingScreenState(_ payload: GhosttyRemoteSessionStatePayload) -> GhosttyRemoteSessionStatePayload {
        GhosttyRemoteSessionStatePayload(
            sessionID: payload.sessionID,
            reason: payload.reason,
            emittedAt: payload.emittedAt,
            sessionStateRevision: payload.sessionStateRevision,
            sessionStateFlags: payload.sessionStateFlags,
            screenStateRevision: nil,
            runtimeState: payload.runtimeState,
            attachmentSnapshot: payload.attachmentSnapshot,
            title: payload.title,
            workingDirectory: payload.workingDirectory,
            snapshot: nil,
            snapshotText: nil,
            transcriptTail: payload.transcriptTail,
            outputByteCount: payload.outputByteCount,
            outputData: payload.outputData
        )
    }

    private func applyLatestState(_ payload: GhosttyRemoteSessionStatePayload) {
        let wasOwner = isOwner
        latestState = latestState?.merged(with: payload) ?? payload
        if payload.attachmentSnapshot != nil {
            isAwaitingTakeoverConfirmation = false
            hasAttachedToSession = activeAttachmentExists(in: payload.attachmentSnapshot)
        }
        let isOwnerAfterMerge = isOwner
        if isOwnerAfterMerge, let outputData = payload.outputData, !outputData.isEmpty, ownerRenderEpochState != nil, payload.reason != "initial" {
            appendOwnerRenderOutput(data: outputData, token: payload.emittedAt)
        }
        if !isOwnerAfterMerge {
            if wasOwner, let latestState {
                self.latestState = payloadByClearingScreenState(latestState)
            }
            hasConfirmedOwnerInputReadiness = false
            isInputSurfaceReady = false
            lastSentResizeSize = nil
            ownerRenderEpochState = nil
            needsOwnershipSynchronizationAfterCurrentRun = false
            ownershipSynchronizationTask?.cancel()
            ownershipSynchronizationTask = nil
            historySeedTask?.cancel()
            historySeedTask = nil
            requestedHistorySeedEpochID = nil
            reportedOwnerReadyEpochID = nil
            isOwnershipSynchronizationScheduled = false
            isSynchronizingOwnership = false
        }
        isSessionUnavailable = false
        errorMessage = nil
        isConnecting = false
        trace(
            "apply_state reason=\(payload.reason) owner_before=\(wasOwner ? 1 : 0) owner_after=\(isOwnerAfterMerge ? 1 : 0) awaiting_takeover=\(isAwaitingTakeoverConfirmation ? 1 : 0) runtime=\(traceSize(columns: latestState?.runtimeState?.columns, rows: latestState?.runtimeState?.rows)) snapshot=\(traceSize(columns: latestState?.snapshot?.columns, rows: latestState?.snapshot?.rows)) screen_revision=\(latestState?.screenStateRevision.map(String.init) ?? "nil") owner_client=\(traceOwnerID(latestState?.attachmentSnapshot))")
        if isOwnerAfterMerge, !wasOwner || ownerRenderEpochState == nil {
            beginOwnerRecoveryGracePeriod()
            scheduleOwnershipSynchronization()
        }
        attemptAutomaticTakeoverIfNeeded()
    }

    func markOwnerRenderOutputApplied(_ batchID: String) {
        guard var ownerRenderEpochState,
            let appliedBatchIndex = ownerRenderEpochState.pendingOutputs.firstIndex(where: { $0.id == batchID })
        else { return }
        ownerRenderEpochState = GhosttyRemoteTerminalOwnerEpoch(
            sessionID: ownerRenderEpochState.sessionID,
            id: ownerRenderEpochState.id,
            bootstrapSnapshot: ownerRenderEpochState.bootstrapSnapshot,
            historySeed: ownerRenderEpochState.historySeed,
            pendingOutputs: Array(ownerRenderEpochState.pendingOutputs.dropFirst(appliedBatchIndex + 1))
        )
        self.ownerRenderEpochState = ownerRenderEpochState
    }

    func markOwnerHistorySeedApplied(_ batchID: String) {
        guard var ownerRenderEpochState, ownerRenderEpochState.historySeed?.id == batchID else { return }
        ownerRenderEpochState = GhosttyRemoteTerminalOwnerEpoch(
            sessionID: ownerRenderEpochState.sessionID,
            id: ownerRenderEpochState.id,
            bootstrapSnapshot: ownerRenderEpochState.bootstrapSnapshot,
            pendingOutputs: ownerRenderEpochState.pendingOutputs
        )
        self.ownerRenderEpochState = ownerRenderEpochState
    }

    func setInputSurfaceReady(_ ready: Bool) {
        if ready {
            trace("host_input_readiness ready=1 accepts_input=\(acceptsInput ? 1 : 0)")
            isInputSurfaceReady = true
            handleOwnerInputSurfaceReady()
            return
        }
        guard !(isOwner && hasConfirmedOwnerInputReadiness && ownerRenderEpochState != nil && !isSessionUnavailable) else {
            trace("host_input_readiness ready=0 ignored_after_owner_ready")
            return
        }
        guard !(hasConfirmedOwnerInputReadiness && acceptsInput) else { return }
        guard !(shouldReconnectSilently && acceptsInput) else { return }
        trace("host_input_readiness ready=0 accepts_input=\(acceptsInput ? 1 : 0)")
        isInputSurfaceReady = false
    }

    private func handleOwnerInputSurfaceReady() {
        guard isOwner, let ownerRenderEpochState else { return }
        hasConfirmedOwnerInputReadiness = true
        if reportedOwnerReadyEpochID != ownerRenderEpochState.id {
            reportedOwnerReadyEpochID = ownerRenderEpochState.id
            logPerformanceEvent(
                name: "owner_first_input_ready",
                attributes: [
                    "epoch_id": ownerRenderEpochState.id,
                    "render_mode": renderMode,
                ]
            )
        }
    }

    private func requestHistorySeedIfNeeded() {
        guard isOwner, let ownerRenderEpochState else { return }
        guard ownerRenderEpochState.historySeed == nil else { return }
        guard requestedHistorySeedEpochID != ownerRenderEpochState.id else { return }
        requestedHistorySeedEpochID = ownerRenderEpochState.id
        historySeedTask?.cancel()
        historySeedTask = Task { [weak self] in
            guard let self else { return }
            defer { self.historySeedTask = nil }
            let fetchedState = await self.refreshLatestState(
                timeout: Self.inputRequestTimeout,
                includeOutputHistory: true,
                applyToLatestState: false,
                reason: "owner_history_seed"
            )
            guard !Task.isCancelled else { return }
            guard self.isOwner, var currentEpoch = self.ownerRenderEpochState, currentEpoch.id == ownerRenderEpochState.id else { return }
            guard let outputData = fetchedState?.outputData, !outputData.isEmpty else { return }
            let historySeedID = "history|\(currentEpoch.id)"
            currentEpoch = GhosttyRemoteTerminalOwnerEpoch(
                sessionID: currentEpoch.sessionID,
                id: currentEpoch.id,
                bootstrapSnapshot: currentEpoch.bootstrapSnapshot,
                historySeed: GhosttyRemoteTerminalOutputBatch(id: historySeedID, data: outputData),
                pendingOutputs: currentEpoch.pendingOutputs
            )
            self.ownerRenderEpochState = currentEpoch
            self.logPerformanceEvent(
                name: "owner_history_seed_received",
                count: outputData.count,
                attributes: [
                    "epoch_id": currentEpoch.id,
                ]
            )
        }
    }

    private func writeE2EEventIfNeeded(kind: String, detail: String?) {
        guard e2eConfig.isEnabled, e2eConfig.matches(sessionID: session.id) else { return }
        SpacesMobileE2EDumpWriter.appendEvent(
            .init(
                sessionID: session.id,
                kind: kind,
                detail: detail,
                emittedAt: ISO8601DateFormatter().string(from: Date())
            ),
            config: e2eConfig
        )
    }

    private func logPerformanceEvent(name: String, elapsedMS: Int? = nil, count: Int? = nil, attributes: [String: String] = [:]) {
        SpacesMobileTerminalPerformanceLogger.emit(
            .init(
                sessionID: session.id,
                source: "ios-viewer",
                name: name,
                elapsedMS: elapsedMS,
                count: count,
                attributes: attributes
            )
        )
    }

    private func trace(_ message: @autoclosure () -> String) {
        terminalViewerTrace(session.id, message())
    }

    private func traceSize(columns: Int?, rows: Int?) -> String {
        guard let columns, let rows else { return "nil" }
        return "\(columns)x\(rows)"
    }

    private func traceOwnerID(_ snapshot: TerminalSessionAttachmentSnapshot?) -> String {
        snapshot?.attachments.first(where: { $0.mode == .owner && $0.detachedAt == nil })?.clientID ?? "nil"
    }

    private func sanitizedTraceDetail(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func traceDurationMilliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let seconds = components.seconds
        let attoseconds = components.attoseconds
        return Int(seconds * 1_000) + Int(attoseconds / 1_000_000_000_000_000)
    }

    private func beginOwnerRenderEpoch(from payload: GhosttyRemoteSessionStatePayload?) {
        guard let payload, isOwner else { return }
        guard let bootstrapSnapshot = payload.snapshot else { return }
        historySeedTask?.cancel()
        historySeedTask = nil
        requestedHistorySeedEpochID = nil
        reportedOwnerReadyEpochID = nil
        hasConfirmedOwnerInputReadiness = false
        let epochID = ownerRenderEpochID(for: payload)
        let historySeed: GhosttyRemoteTerminalOutputBatch? =
            if let outputData = payload.outputData, !outputData.isEmpty {
                GhosttyRemoteTerminalOutputBatch(id: "history|\(epochID)", data: outputData)
            } else {
                nil
            }
        ownerRenderEpochState = GhosttyRemoteTerminalOwnerEpoch(
            sessionID: session.id,
            id: epochID,
            bootstrapSnapshot: bootstrapSnapshot,
            historySeed: historySeed,
            pendingOutputs: []
        )
        trace(
            "owner_render_epoch_begin id=\(epochID) snapshot=1"
        )
        logPerformanceEvent(
            name: "owner_bootstrap_state_received",
            attributes: [
                "epoch_id": epochID,
                "payload_reason": payload.reason,
                "snapshot_columns": String(bootstrapSnapshot.columns),
                "snapshot_rows": String(bootstrapSnapshot.rows),
            ]
        )
        if isInputSurfaceReady { handleOwnerInputSurfaceReady() }
        requestHistorySeedIfNeeded()
    }

    private func appendOwnerRenderOutput(data: Data, token: String) {
        guard var ownerRenderEpochState else { return }
        let combinedHistorySeed: GhosttyRemoteTerminalOutputBatch? =
            if let historySeed = ownerRenderEpochState.historySeed {
                GhosttyRemoteTerminalOutputBatch(id: historySeed.id, data: historySeed.data + data)
            } else {
                nil
            }
        var pendingOutputs = ownerRenderEpochState.pendingOutputs
        pendingOutputs.append(GhosttyRemoteTerminalOutputBatch(id: token, data: data))
        ownerRenderEpochState = GhosttyRemoteTerminalOwnerEpoch(
            sessionID: ownerRenderEpochState.sessionID,
            id: ownerRenderEpochState.id,
            bootstrapSnapshot: ownerRenderEpochState.bootstrapSnapshot,
            historySeed: combinedHistorySeed,
            pendingOutputs: pendingOutputs
        )
        self.ownerRenderEpochState = ownerRenderEpochState
    }

    private func ownerRenderEpochID(for payload: GhosttyRemoteSessionStatePayload) -> String {
        let runtimeColumns = payload.runtimeState?.columns ?? 0
        let runtimeRows = payload.runtimeState?.rows ?? 0
        let screenRevision = payload.screenStateRevision ?? 0
        return "owner|\(payload.emittedAt)|\(screenRevision)|\(runtimeColumns)x\(runtimeRows)"
    }

    private func endedRenderID(for snapshot: GhosttyTerminalSnapshot) -> String {
        let screenRevision = latestState?.screenStateRevision ?? 0
        return "ended|\(screenRevision)|\(snapshot.columns)x\(snapshot.rows)|\(latestState?.emittedAt ?? "unknown")"
    }
}
