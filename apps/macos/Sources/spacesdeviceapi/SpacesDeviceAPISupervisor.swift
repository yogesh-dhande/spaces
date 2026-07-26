import Foundation
import spacesdevicecore
import spacesterminalcore
import workspacecore

@MainActor public final class SpacesDeviceAPISupervisor {
    private let settingsStore: SpacesDeviceAPISettingsStore
    private let environment: [String: String]
    private let restartInterval: TimeInterval
    private let builtInTerminalSessionTerminator: WorkspaceOrchestrator.BuiltInTerminalSessionTerminator?
    private let builtInTerminalSessionLauncher: WorkspaceOrchestrator.BuiltInTerminalSessionLauncher?
    private let agentSessionKiller: (@Sendable (String) throws -> Bool)?
    private let onRestartRequested: (@Sendable () -> Void)?

    private var server: SpacesDeviceAPIServer?
    private var advertiser: (any SpacesDeviceAPIBonjourAdvertising)?
    private var controlServer: SpacesDeviceAPIControlServer?
    private var restartTimer: Timer?
    private var isStopped = false
    private var lastFailureDescription: String?

    public init(
        settingsStore: SpacesDeviceAPISettingsStore = SpacesDeviceAPISettingsStore(),
        environment: [String: String] = ProcessInfo.processInfo.environment, restartInterval: TimeInterval = 5,
        builtInTerminalSessionTerminator: WorkspaceOrchestrator.BuiltInTerminalSessionTerminator? = nil,
        builtInTerminalSessionLauncher: WorkspaceOrchestrator.BuiltInTerminalSessionLauncher? = nil,
        agentSessionKiller: (@Sendable (String) throws -> Bool)? = nil, onRestartRequested: (@Sendable () -> Void)? = nil
    ) {
        self.settingsStore = settingsStore
        self.environment = environment
        self.restartInterval = restartInterval
        self.builtInTerminalSessionTerminator = builtInTerminalSessionTerminator
        self.builtInTerminalSessionLauncher = builtInTerminalSessionLauncher
        self.agentSessionKiller = agentSessionKiller
        self.onRestartRequested = onRestartRequested
    }

    public func start() {
        guard !isDisabled else { return }
        isStopped = false
        startControlServerIfNeeded()
        startRestartTimer()
        startDeviceAPIIfNeeded()
    }

    public func stop() {
        isStopped = true
        restartTimer?.invalidate()
        restartTimer = nil
        controlServer?.stop()
        controlServer = nil
        advertiser?.stop()
        advertiser = nil
        server?.stop()
        server = nil
    }

    public func status() throws -> SpacesDeviceAPIStatus {
        let certificateFingerprint: String
        if let server {
            certificateFingerprint = server.certificateFingerprint
        } else {
            certificateFingerprint = try TerminalServiceTLSIdentityStore.loadOrCreate().certificateFingerprint
        }
        let status = try settingsStore.status(certificateFingerprint: certificateFingerprint)
        return SpacesDeviceAPIStatus(
            host: status.host, port: server?.listeningPort ?? status.port, bonjourServiceName: status.bonjourServiceName,
            bonjourServiceType: status.bonjourServiceType, networkAddresses: status.networkAddresses,
            certificateFingerprint: status.certificateFingerprint)
    }

    private var isDisabled: Bool { SpacesDeviceAPIDefaults.isDisabledByEnvironment(environment) }

    private func startRestartTimer() {
        restartTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: restartInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.startDeviceAPIIfNeeded() }
        }
        RunLoop.main.add(timer, forMode: .common)
        restartTimer = timer
    }

    private func startDeviceAPIIfNeeded() {
        if let existingServer = server, !existingServer.isRunning {
            advertiser?.stop()
            advertiser = nil
            // Tear the dead server down before dropping the reference: its connections, stream
            // relays, and observers stay alive otherwise, so every restart would leak another set
            // of sockets and timers into the daemon.
            existingServer.stop()
            server = nil
            log("Device API listener stopped; scheduling restart")
        }
        guard !isStopped, server == nil else { return }
        do {
            let settings = try settingsStore.loadOrCreate()
            let createdServer = try startDeviceAPIServer(settings: settings)
            let serviceName = try SpacesDeviceAPISettingsStore.bonjourServiceName()
            let createdAdvertiser = SpacesDeviceAPIBonjourAdvertiser(
                serviceName: serviceName, port: createdServer.listeningPort,
                txtRecord: ["kind": "spaces-device-api", "bundle": SpacesDeviceFirstPartyPolicy.allowedBundleID])
            createdAdvertiser.publish()
            server = createdServer
            advertiser = createdAdvertiser
            lastFailureDescription = nil
            log("Device API listening host=\(settings.host) port=\(createdServer.listeningPort) service=\"\(serviceName)\"")
        } catch {
            let description = String(describing: error)
            if description != lastFailureDescription {
                log("Device API unavailable: \(description)")
                lastFailureDescription = description
            }
        }
    }

    private func startDeviceAPIServer(settings: SpacesDeviceAPISettings) throws -> SpacesDeviceAPIServer {
        let identity = try TerminalServiceTLSIdentityStore.loadOrCreate()
        let createdServer = SpacesDeviceAPIServer(
            host: settings.host, port: settings.port, identity: identity, pairingStoreProtocol: try SpacesDevicePairingStore(),
            builtInTerminalSessionTerminator: builtInTerminalSessionTerminator, builtInTerminalSessionLauncher: builtInTerminalSessionLauncher,
            agentSessionKiller: agentSessionKiller, onRestartRequested: onRestartRequested)
        do {
            try createdServer.start()
            return createdServer
        } catch {
            createdServer.stop()
            throw error
        }
    }

    private func startControlServerIfNeeded() {
        guard controlServer == nil else { return }
        do {
            let socketPath = try SpacesDeviceAPIControlClient.socketPath()
            let queue = DispatchQueue(label: "spaces.device.api.control")
            let createdServer = SpacesDeviceAPIControlServer(socketPath: socketPath, queue: queue) { [weak self] request in
                Self.runOnMainActorSynchronously {
                    guard let self else { return SpacesDeviceAPIControlResponse(ok: false, message: "Device API supervisor is unavailable.") }
                    return self.handleControlRequest(request)
                }
            }
            try createdServer.start()
            controlServer = createdServer
        } catch { log("Device API control unavailable: \(String(describing: error))") }
    }

    private func handleControlRequest(_ request: SpacesDeviceAPIControlRequest) -> SpacesDeviceAPIControlResponse {
        do {
            switch request.command {
            case .status:
                startDeviceAPIIfNeeded()
                let currentStatus = try status()
                let result = SpacesDeviceAPIControlStatusResult(
                    status: currentStatus, pairingWindow: server?.pairingWindowSnapshot(), devices: try pairedDevices())
                guard server != nil else {
                    return SpacesDeviceAPIControlResponse(
                        ok: false, message: SpacesDeviceAPIControlClient.deviceAPINotRunningMessage, result: .status(result))
                }
                return SpacesDeviceAPIControlResponse(ok: true, message: "Loaded Device API status.", result: .status(result))
            case .openPairingWindow:
                startDeviceAPIIfNeeded()
                guard let server else {
                    return SpacesDeviceAPIControlResponse(
                        ok: false, message: SpacesDeviceAPIControlClient.deviceAPINotRunningMessage, result: .status(.init(status: try status())))
                }
                let currentStatus = try status()
                let window = server.openPairingWindow(hosts: pairingLinkHosts(for: currentStatus), name: currentStatus.bonjourServiceName)
                return SpacesDeviceAPIControlResponse(
                    ok: true, message: "Opened device pairing window.",
                    result: .pairingWindow(
                        .init(status: currentStatus, pairingWindow: SpacesDevicePairingWindowSnapshot(window: window), devices: try pairedDevices())))
            case .listDevices:
                return SpacesDeviceAPIControlResponse(ok: true, message: "Loaded paired devices.", result: .devices(try pairedDevices()))
            case .bootstrapLocalClient(let payload): return try handleBootstrapLocalClient(payload)
            case .revokeDevice(let payload):
                let devices = try revokePairing(installationID: payload.installationID)
                return SpacesDeviceAPIControlResponse(ok: true, message: "Revoked paired device.", result: .devices(devices))
            case .resetAllPairings:
                try resetPairings()
                // Regenerate the daemon TLS identity so every previously pinned client fails closed
                // until it re-pairs against the new certificate fingerprint.
                let identityRoot = try TerminalServiceTLSIdentityStore.rootDirectory()
                if FileManager.default.fileExists(atPath: identityRoot.path) { try FileManager.default.removeItem(at: identityRoot) }
                _ = try TerminalServiceTLSIdentityStore.loadOrCreate()
                advertiser?.stop()
                advertiser = nil
                server = nil
                return SpacesDeviceAPIControlResponse(ok: true, message: "Reset all device pairings.", result: .devices([]))
            }
        } catch { return SpacesDeviceAPIControlResponse(ok: false, message: String(describing: error)) }
    }

    private func handleBootstrapLocalClient(_ request: SpacesDeviceAPIControlBootstrapLocalClientRequest) throws -> SpacesDeviceAPIControlResponse {
        let clientApp = request.clientApp
        startDeviceAPIIfNeeded()
        guard server != nil else {
            return SpacesDeviceAPIControlResponse(
                ok: false, message: SpacesDeviceAPIControlClient.deviceAPINotRunningMessage, result: .status(.init(status: try status())))
        }
        let currentStatus = try status()
        let authToken = try SpacesDevicePairingStore().issueToken(for: clientApp, presentedToken: request.presentedToken)
        let bootstrap = SpacesDeviceAPILocalClientBootstrap(
            deviceID: "local", name: currentStatus.bonjourServiceName, platform: "macos", host: SpacesDeviceAPIDefaults.loopbackHost,
            port: currentStatus.port, certificateFingerprint: currentStatus.certificateFingerprint, authToken: authToken)
        return SpacesDeviceAPIControlResponse(ok: true, message: "Bootstrapped local Device API client.", result: .localClientBootstrap(bootstrap))
    }

    private func pairedDevices() throws -> [SpacesDevicePairedClient] { try SpacesDevicePairingStore().listDevices() }

    private func revokePairing(installationID: String) throws -> [SpacesDevicePairedClient] {
        let store = try SpacesDevicePairingStore()
        try store.revoke(installationID: installationID)
        server?.closeStreamRelays(forInstallationID: installationID)
        return try store.listDevices()
    }

    private func resetPairings() throws {
        try SpacesDevicePairingStore().removeAll()
        server?.stop()
        server = nil
    }

    private func pairingLinkHosts(for status: SpacesDeviceAPIStatus) -> [String] {
        SpacesDeviceAPINetworkInterfaces.pairingLinkHosts(boundHost: status.host)
    }

    private func log(_ message: String) { FileHandle.standardError.write(Data("spacesd: \(message)\n".utf8)) }

    private nonisolated static func runOnMainActorSynchronously<T: Sendable>(_ work: @escaping @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated { work() } }
        let box = SpacesDeviceAPIMainActorSyncBox<T>()
        DispatchQueue.main.sync { box.value = MainActor.assumeIsolated { work() } }
        guard let value = box.value else { preconditionFailure("Device API main-actor work did not return a value.") }
        return value
    }
}

private final class SpacesDeviceAPIMainActorSyncBox<T>: @unchecked Sendable { var value: T? }

@MainActor private protocol SpacesDeviceAPIBonjourAdvertising: AnyObject {
    func publish()
    func stop()
}

#if canImport(Darwin)
    @MainActor private final class SpacesDeviceAPIBonjourAdvertiser: SpacesDeviceAPIBonjourAdvertising {
        private let serviceName: String
        private let port: Int
        private let txtRecord: [String: String]
        private var service: NetService?

        init(serviceName: String, port: Int, txtRecord: [String: String]) {
            self.serviceName = serviceName
            self.port = port
            self.txtRecord = txtRecord
        }

        func publish() {
            let service = NetService(domain: "local.", type: SpacesDeviceAPIDefaults.bonjourServiceType, name: serviceName, port: Int32(port))
            let txtData = NetService.data(fromTXTRecord: txtRecord.mapValues { Data($0.utf8) })
            service.setTXTRecord(txtData)
            service.publish()
            self.service = service
        }

        func stop() {
            service?.stop()
            service = nil
        }
    }
#else
    @MainActor private final class SpacesDeviceAPIBonjourAdvertiser: SpacesDeviceAPIBonjourAdvertising {
        init(serviceName: String, port: Int, txtRecord: [String: String]) {}
        func publish() {}
        func stop() {}
    }
#endif
