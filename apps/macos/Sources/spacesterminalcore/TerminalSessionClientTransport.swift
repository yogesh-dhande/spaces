import Dispatch
import Foundation

public struct TerminalSessionClientSnapshot: Sendable, Equatable {
    public let launchConfiguration: TerminalSessionLaunchConfiguration?
    public let runtimeState: TerminalSessionRuntimeState?
    public let attachmentSnapshot: TerminalSessionAttachmentSnapshot?
    public let recentOutput: String
    public let outputByteCount: Int64

    public init(
        launchConfiguration: TerminalSessionLaunchConfiguration?, runtimeState: TerminalSessionRuntimeState?,
        attachmentSnapshot: TerminalSessionAttachmentSnapshot?, recentOutput: String, outputByteCount: Int64
    ) {
        self.launchConfiguration = launchConfiguration
        self.runtimeState = runtimeState
        self.attachmentSnapshot = attachmentSnapshot
        self.recentOutput = recentOutput
        self.outputByteCount = outputByteCount
    }
}

extension TerminalSessionClientSnapshot {
    init(hostSnapshot: TerminalSessionHostSnapshot) {
        self.init(
            launchConfiguration: hostSnapshot.launchConfiguration, runtimeState: hostSnapshot.runtimeState,
            attachmentSnapshot: hostSnapshot.attachmentSnapshot, recentOutput: hostSnapshot.recentOutput,
            outputByteCount: hostSnapshot.outputByteCount)
    }
}

public enum TerminalSessionClientEvent: Sendable, Equatable {
    case snapshotChanged
    case outputChanged(byteCount: Int, recentOutput: String)
}

private final class LocalTerminalSessionOutputCache: @unchecked Sendable {
    private let queue = DispatchQueue(label: "spaces.terminal.client-transport.output-cache")
    private var cachedOutput: String?

    func current(path: String, lineCount: Int) -> String {
        queue.sync {
            if let cachedOutput { return cachedOutput }
            let loaded = (try? TerminalOutputTail.tail(path: path, lineCount: lineCount)) ?? ""
            cachedOutput = loaded
            return loaded
        }
    }

    func refresh(path: String, lineCount: Int) -> String {
        let loaded = (try? TerminalOutputTail.tail(path: path, lineCount: lineCount)) ?? ""
        return queue.sync {
            cachedOutput = loaded
            return loaded
        }
    }
}

public final class TerminalSessionClientTransportObservation {
    private let cancelAction: () -> Void
    private var isCancelled = false

    public init(cancelAction: @escaping () -> Void) { self.cancelAction = cancelAction }

    deinit { cancel() }

    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        cancelAction()
    }
}

public struct TerminalSessionClientTransport {
    public let loadSnapshot: @Sendable () throws -> TerminalSessionClientSnapshot
    public let currentOutputSize: @Sendable () throws -> Int64
    public let readOutputChunk: @Sendable (Int64, Int) throws -> TerminalOutputChunk?
    public let sendInput: @Sendable (String, Bool, String) throws -> TerminalControlResponse
    public let sendKey: @Sendable (String, String) throws -> TerminalControlResponse
    public let sendMouse: @Sendable (String, String) throws -> TerminalControlResponse
    public let resize: @Sendable (Int, Int, String) throws -> TerminalControlResponse
    public let takeover: @Sendable (String) throws -> TerminalControlResponse
    public let terminate: @Sendable (String?) throws -> TerminalControlResponse
    public let attachClient: @Sendable (TerminalClient, TerminalAttachmentMode) throws -> Void
    public let detachClient: @Sendable (String) throws -> Void
    public let loadWindowFrame: (TerminalAttachmentMode) throws -> TerminalSessionWindowFrame?
    public let saveWindowFrame: (TerminalSessionWindowFrame, TerminalAttachmentMode) throws -> Void
    public let observe: (@escaping @Sendable (TerminalSessionClientEvent) -> Void) -> TerminalSessionClientTransportObservation

    public init(
        loadSnapshot: @escaping @Sendable () throws -> TerminalSessionClientSnapshot, currentOutputSize: @escaping @Sendable () throws -> Int64,
        readOutputChunk: @escaping @Sendable (Int64, Int) throws -> TerminalOutputChunk?,
        sendInput: @escaping @Sendable (String, Bool, String) throws -> TerminalControlResponse,
        sendKey: @escaping @Sendable (String, String) throws -> TerminalControlResponse,
        sendMouse: @escaping @Sendable (String, String) throws -> TerminalControlResponse,
        resize: @escaping @Sendable (Int, Int, String) throws -> TerminalControlResponse,
        takeover: @escaping @Sendable (String) throws -> TerminalControlResponse,
        terminate: @escaping @Sendable (String?) throws -> TerminalControlResponse,
        attachClient: @escaping @Sendable (TerminalClient, TerminalAttachmentMode) throws -> Void,
        detachClient: @escaping @Sendable (String) throws -> Void,
        loadWindowFrame: @escaping (TerminalAttachmentMode) throws -> TerminalSessionWindowFrame?,
        saveWindowFrame: @escaping (TerminalSessionWindowFrame, TerminalAttachmentMode) throws -> Void,
        observe: @escaping (@escaping @Sendable (TerminalSessionClientEvent) -> Void) -> TerminalSessionClientTransportObservation
    ) {
        self.loadSnapshot = loadSnapshot
        self.currentOutputSize = currentOutputSize
        self.readOutputChunk = readOutputChunk
        self.sendInput = sendInput
        self.sendKey = sendKey
        self.sendMouse = sendMouse
        self.resize = resize
        self.takeover = takeover
        self.terminate = terminate
        self.attachClient = attachClient
        self.detachClient = detachClient
        self.loadWindowFrame = loadWindowFrame
        self.saveWindowFrame = saveWindowFrame
        self.observe = observe
    }

    public static func local(
        sessionID: String, paths: TerminalSessionPaths, outputLineCount: Int = 200, notificationCenter: NotificationCenter = .default,
        sendInputAction: (@Sendable (String, Bool, String) throws -> TerminalControlResponse)? = nil,
        sendKeyAction: (@Sendable (String, String) throws -> TerminalControlResponse)? = nil,
        sendMouseAction: (@Sendable (String, String) throws -> TerminalControlResponse)? = nil,
        resizeAction: (@Sendable (Int, Int, String) throws -> TerminalControlResponse)? = nil,
        takeoverAction: (@Sendable (String) throws -> TerminalControlResponse)? = nil,
        terminateAction: (@Sendable (String?) throws -> TerminalControlResponse)? = nil,
        attachClientAction: (@Sendable (TerminalClient, TerminalAttachmentMode) throws -> Void)? = nil,
        detachClientAction: (@Sendable (String) throws -> Void)? = nil,
        loadWindowFrameAction: ((TerminalAttachmentMode) throws -> TerminalSessionWindowFrame?)? = nil,
        saveWindowFrameAction: ((TerminalSessionWindowFrame, TerminalAttachmentMode) throws -> Void)? = nil
    ) -> Self {
        let socketPath = paths.controlSocketPath
        let outputPath = paths.outputPath
        let outputCache = LocalTerminalSessionOutputCache()
        let hostConnection = TerminalSessionHostConnection.localSocket(path: socketPath)

        @Sendable func loadSnapshotFromFiles() -> TerminalSessionClientSnapshot {
            TerminalSessionClientSnapshot(
                launchConfiguration: try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths),
                runtimeState: try? TerminalSessionPersistence.readRuntimeState(paths: paths),
                attachmentSnapshot: try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths),
                recentOutput: outputCache.refresh(path: outputPath, lineCount: outputLineCount),
                outputByteCount: (try? TerminalOutputChunkReader.currentSize(path: outputPath)) ?? 0)
        }

        return hostBacked(
            sessionID: sessionID, paths: paths, hostConnection: hostConnection, outputLineCount: outputLineCount,
            notificationCenter: notificationCenter, sendInputAction: sendInputAction, sendKeyAction: sendKeyAction, sendMouseAction: sendMouseAction,
            resizeAction: resizeAction, takeoverAction: takeoverAction, terminateAction: terminateAction, attachClientAction: attachClientAction,
            detachClientAction: detachClientAction, loadWindowFrameAction: loadWindowFrameAction, saveWindowFrameAction: saveWindowFrameAction,
            loadSnapshotFromFiles: loadSnapshotFromFiles)
    }

    public static func hostBacked(
        sessionID: String, paths: TerminalSessionPaths, hostConnection: TerminalSessionHostConnection, outputLineCount: Int = 200,
        notificationCenter: NotificationCenter = .default,
        sendInputAction: (@Sendable (String, Bool, String) throws -> TerminalControlResponse)? = nil,
        sendKeyAction: (@Sendable (String, String) throws -> TerminalControlResponse)? = nil,
        sendMouseAction: (@Sendable (String, String) throws -> TerminalControlResponse)? = nil,
        resizeAction: (@Sendable (Int, Int, String) throws -> TerminalControlResponse)? = nil,
        takeoverAction: (@Sendable (String) throws -> TerminalControlResponse)? = nil,
        terminateAction: (@Sendable (String?) throws -> TerminalControlResponse)? = nil,
        attachClientAction: (@Sendable (TerminalClient, TerminalAttachmentMode) throws -> Void)? = nil,
        detachClientAction: (@Sendable (String) throws -> Void)? = nil,
        loadWindowFrameAction: ((TerminalAttachmentMode) throws -> TerminalSessionWindowFrame?)? = nil,
        saveWindowFrameAction: ((TerminalSessionWindowFrame, TerminalAttachmentMode) throws -> Void)? = nil,
        loadSnapshotFromFiles: (@Sendable () -> TerminalSessionClientSnapshot)? = nil
    ) -> Self {
        let sessionRoot = paths.rootDirectory
        let metadataPath = paths.metadataPath
        let statePath = paths.statePath
        let outputPath = paths.outputPath
        let attachmentsPath = paths.attachmentsPath
        let clientsPath = paths.clientsPath
        let outputCache = LocalTerminalSessionOutputCache()

        let fileSnapshotLoader =
            loadSnapshotFromFiles ?? {
                TerminalSessionClientSnapshot(
                    launchConfiguration: try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths),
                    runtimeState: try? TerminalSessionPersistence.readRuntimeState(paths: paths),
                    attachmentSnapshot: try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths),
                    recentOutput: outputCache.refresh(path: outputPath, lineCount: outputLineCount),
                    outputByteCount: (try? TerminalOutputChunkReader.currentSize(path: outputPath)) ?? 0)
            }

        return Self(
            loadSnapshot: {
                if hostConnection.isAvailable() {
                    do {
                        let response = try hostConnection.send(TerminalControlRequest(command: "snapshot", recentOutputLineCount: outputLineCount))
                        if response.ok, let snapshot = response.snapshot { return TerminalSessionClientSnapshot(hostSnapshot: snapshot) }
                    } catch {}
                }
                return fileSnapshotLoader()
            },
            currentOutputSize: {
                if hostConnection.isAvailable() {
                    do {
                        let response = try hostConnection.send(TerminalControlRequest(command: "output_size"))
                        if response.ok, let outputByteCount = response.outputByteCount { return outputByteCount }
                    } catch {}
                }
                return try TerminalOutputChunkReader.currentSize(path: outputPath)
            },
            readOutputChunk: { offset, maximumBytes in
                if hostConnection.isAvailable() {
                    do {
                        let response = try hostConnection.send(
                            TerminalControlRequest(command: "read_output_chunk", offset: offset, maximumBytes: maximumBytes))
                        if response.ok { return response.outputChunk }
                    } catch {}
                }
                return try TerminalOutputChunkReader.readChunk(sessionID: sessionID, path: outputPath, offset: offset, maximumBytes: maximumBytes)
            },
            sendInput: sendInputAction ?? { text, appendNewline, clientID in
                try hostConnection.send(TerminalControlRequest(command: "send", text: text, clientID: clientID, appendNewline: appendNewline))
            },
            sendKey: sendKeyAction ?? { key, clientID in try hostConnection.send(TerminalControlRequest(command: "key", key: key, clientID: clientID))
            },
            sendMouse: sendMouseAction ?? { sequence, clientID in
                try hostConnection.send(TerminalControlRequest(command: "mouse", clientID: clientID, mouseSequence: sequence))
            },
            resize: resizeAction ?? { columns, rows, clientID in
                try hostConnection.send(TerminalControlRequest(command: "resize", clientID: clientID, columns: columns, rows: rows))
            }, takeover: takeoverAction ?? { clientID in try hostConnection.send(TerminalControlRequest(command: "takeover", clientID: clientID)) },
            terminate: terminateAction ?? { clientID in try hostConnection.send(TerminalControlRequest(command: "terminate", clientID: clientID)) },
            attachClient: attachClientAction ?? { client, mode in
                if hostConnection.isAvailable() {
                    do {
                        let response = try hostConnection.send(TerminalControlRequest(command: "attach", client: client, attachmentMode: mode))
                        if response.ok { return }
                    } catch {}
                }
                try TerminalSessionPersistence.attachClient(
                    sessionID: sessionID, client: client, mode: mode, paths: paths, attachedAt: ISO8601DateFormatter().string(from: Date()))
            },
            detachClient: detachClientAction ?? { clientID in
                if hostConnection.isAvailable() {
                    do {
                        let response = try hostConnection.send(TerminalControlRequest(command: "detach", clientID: clientID))
                        if response.ok { return }
                    } catch {}
                }
                try TerminalSessionPersistence.detachClient(id: clientID, paths: paths, detachedAt: ISO8601DateFormatter().string(from: Date()))
            }, loadWindowFrame: loadWindowFrameAction ?? { mode in try TerminalSessionPersistence.readWindowFrame(mode: mode, paths: paths) },
            saveWindowFrame: saveWindowFrameAction ?? { frame, mode in
                try TerminalSessionPersistence.writeWindowFrame(frame, mode: mode, paths: paths)
            },
            observe: { handler in
                let tokens = [
                    notificationCenter.addObserver(forName: .spacesTerminalAttachmentStateDidChange, object: nil, queue: nil) { notification in
                        guard notification.userInfo?["sessionID"] as? String == sessionID else { return }
                        handler(.snapshotChanged)
                    },
                    notificationCenter.addObserver(forName: .spacesTerminalSessionMetadataDidChange, object: nil, queue: nil) { notification in
                        guard notification.userInfo?["sessionID"] as? String == sessionID else { return }
                        handler(.snapshotChanged)
                    },
                    notificationCenter.addObserver(forName: .spacesTerminalRuntimeStateDidChange, object: nil, queue: nil) { notification in
                        guard notification.userInfo?["sessionID"] as? String == sessionID else { return }
                        handler(.snapshotChanged)
                    },
                    notificationCenter.addObserver(forName: .spacesTerminalOutputDidChange, object: nil, queue: nil) { notification in
                        guard notification.userInfo?["sessionID"] as? String == sessionID else { return }
                        let byteCount = notification.userInfo?["byteCount"] as? Int ?? 0
                        let recentOutput = outputCache.refresh(path: outputPath, lineCount: outputLineCount)
                        handler(.outputChanged(byteCount: byteCount, recentOutput: recentOutput))
                    },
                ]

                var sources: [DispatchSourceFileSystemObject] = []
                var fileDescriptors: [Int32] = []
                let queue = DispatchQueue(label: "spaces.terminal.client-transport.\(sessionID)")

                func installWatch(
                    path: String, isDirectory: Bool, eventMask: DispatchSource.FileSystemEvent,
                    eventBuilder: @escaping @Sendable () -> TerminalSessionClientEvent
                ) {
                    guard FileManager.default.fileExists(atPath: path) else { return }
                    let descriptor = open(path, O_EVTONLY)
                    guard descriptor >= 0 else { return }
                    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: eventMask, queue: queue)
                    source.setEventHandler { handler(eventBuilder()) }
                    source.setCancelHandler { close(descriptor) }
                    source.resume()
                    fileDescriptors.append(descriptor)
                    sources.append(source)
                    _ = isDirectory
                }

                installWatch(
                    path: outputPath, isDirectory: false, eventMask: [.write, .extend, .rename, .delete],
                    eventBuilder: { .outputChanged(byteCount: 0, recentOutput: outputCache.refresh(path: outputPath, lineCount: outputLineCount)) })
                if FileManager.default.fileExists(atPath: sessionRoot) {
                    let descriptor = open(sessionRoot, O_EVTONLY)
                    if descriptor >= 0 {
                        let source = DispatchSource.makeFileSystemObjectSource(
                            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: queue)
                        var previousDates = fileDates(paths: [metadataPath, statePath, attachmentsPath, clientsPath])
                        source.setEventHandler {
                            let currentDates = fileDates(paths: [metadataPath, statePath, attachmentsPath, clientsPath])
                            guard currentDates != previousDates else { return }
                            previousDates = currentDates
                            handler(.snapshotChanged)
                        }
                        source.setCancelHandler { close(descriptor) }
                        source.resume()
                        fileDescriptors.append(descriptor)
                        sources.append(source)
                    }
                }

                return TerminalSessionClientTransportObservation {
                    for token in tokens { notificationCenter.removeObserver(token) }
                    for source in sources { source.cancel() }
                    _ = fileDescriptors
                }
            })
    }
}

private func fileDates(paths: [String]) -> [String: Date?] {
    Dictionary(
        uniqueKeysWithValues: paths.map { path in
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey])
            return (path, values?.contentModificationDate)
        })
}
