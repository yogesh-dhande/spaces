import Foundation
import spacesmobilecore

@MainActor public final class SpacesMobileBridgeSupervisor {
    private let settingsStore: SpacesMobileBridgeSettingsStore
    private let environment: [String: String]
    private let restartInterval: TimeInterval

    private var server: SpacesMobileBridgeServer?
    private var advertiser: SpacesMobileBridgeBonjourAdvertiser?
    private var controlServer: SpacesMobileBridgeControlServer?
    private var restartTimer: Timer?
    private var isStopped = false
    private var lastFailureDescription: String?

    public init(
        settingsStore: SpacesMobileBridgeSettingsStore = SpacesMobileBridgeSettingsStore(),
        environment: [String: String] = ProcessInfo.processInfo.environment, restartInterval: TimeInterval = 5
    ) {
        self.settingsStore = settingsStore
        self.environment = environment
        self.restartInterval = restartInterval
    }

    public func start() {
        guard !isDisabled else { return }
        isStopped = false
        startControlServerIfNeeded()
        startRestartTimer()
        startBridgeIfNeeded()
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

    public func status() throws -> SpacesMobileBridgeStatus {
        let status = try settingsStore.status()
        return SpacesMobileBridgeStatus(
            host: status.host, port: server?.listeningPort ?? status.port, bonjourServiceName: status.bonjourServiceName,
            bonjourServiceType: status.bonjourServiceType, networkAddresses: status.networkAddresses)
    }

    private var isDisabled: Bool {
        let value = environment[SpacesMobileBridgeDefaults.disabledEnvironmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value == "1" || value.localizedCaseInsensitiveCompare("true") == .orderedSame
    }

    private func startRestartTimer() {
        restartTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: restartInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.startBridgeIfNeeded() }
        }
        RunLoop.main.add(timer, forMode: .common)
        restartTimer = timer
    }

    private func startBridgeIfNeeded() {
        if let existingServer = server, !existingServer.isRunning {
            advertiser?.stop()
            advertiser = nil
            server = nil
            log("mobile bridge listener stopped; scheduling restart")
        }
        guard !isStopped, server == nil else { return }
        do {
            let settings = try settingsStore.loadOrCreate()
            let createdServer = try startBridgeServer(settings: settings)
            let serviceName = try SpacesMobileBridgeSettingsStore.bonjourServiceName()
            let createdAdvertiser = SpacesMobileBridgeBonjourAdvertiser(
                serviceName: serviceName, port: createdServer.listeningPort,
                txtRecord: ["kind": "spaces-mobile-bridge", "bundle": SpacesMobileFirstPartyPolicy.allowedBundleID])
            createdAdvertiser.publish()
            server = createdServer
            advertiser = createdAdvertiser
            lastFailureDescription = nil
            log("mobile bridge listening host=\(settings.host) port=\(createdServer.listeningPort) service=\"\(serviceName)\"")
        } catch {
            let description = String(describing: error)
            if description != lastFailureDescription {
                log("mobile bridge unavailable: \(description)")
                lastFailureDescription = description
            }
        }
    }

    private func startBridgeServer(settings: SpacesMobileBridgeSettings) throws -> SpacesMobileBridgeServer {
        do { return try startBridgeServer(host: settings.host, port: settings.port, transportKey: settings.transportKey) } catch {
            guard settings.port != 0 else { throw error }
            let configuredPortError = error
            log("mobile bridge configured port \(settings.port) unavailable; retrying on a stable profile port")
            var fallbackError = configuredPortError
            for fallbackPort in try settingsStore.stableFallbackPorts() where fallbackPort != settings.port {
                do {
                    let fallbackServer = try startBridgeServer(host: settings.host, port: fallbackPort, transportKey: settings.transportKey)
                    do { _ = try settingsStore.updatePort(fallbackPort) } catch {
                        fallbackServer.stop()
                        throw error
                    }
                    log("mobile bridge using stable fallback port \(fallbackPort)")
                    return fallbackServer
                } catch { fallbackError = error }
            }
            throw fallbackError
        }
    }

    private func startBridgeServer(host: String, port: Int, transportKey: String) throws -> SpacesMobileBridgeServer {
        let createdServer = try SpacesMobileBridgeServer(host: host, port: port, transportKey: transportKey)
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
            let socketPath = try SpacesMobileBridgeControlClient.socketPath()
            let queue = DispatchQueue(label: "spaces.mobile.bridge.control")
            let createdServer = SpacesMobileBridgeControlServer(socketPath: socketPath, queue: queue) { [weak self] request in
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        guard let self else {
                            return SpacesMobileBridgeControlResponse(ok: false, message: "Mobile bridge supervisor is unavailable.")
                        }
                        return self.handleControlRequest(request)
                    }
                }
            }
            try createdServer.start()
            controlServer = createdServer
        } catch { log("mobile bridge control unavailable: \(String(describing: error))") }
    }

    private func handleControlRequest(_ request: SpacesMobileBridgeControlRequest) -> SpacesMobileBridgeControlResponse {
        do {
            switch request.command {
            case "status":
                return SpacesMobileBridgeControlResponse(
                    ok: true, message: "Loaded mobile bridge status.", status: try status(), pairingWindow: server?.pairingWindowSnapshot(),
                    devices: try pairedDevices())
            case "openPairingWindow":
                startBridgeIfNeeded()
                guard let server else {
                    return SpacesMobileBridgeControlResponse(ok: false, message: "Mobile bridge is not running.", status: try status())
                }
                let currentStatus = try status()
                let window = server.openPairingWindow(host: pairingLinkHost(for: currentStatus), name: currentStatus.bonjourServiceName)
                return SpacesMobileBridgeControlResponse(
                    ok: true, message: "Opened mobile pairing window.", status: currentStatus,
                    pairingWindow: SpacesMobilePairingWindowSnapshot(window: window), devices: try pairedDevices())
            case "listDevices":
                return SpacesMobileBridgeControlResponse(ok: true, message: "Loaded paired mobile devices.", devices: try pairedDevices())
            case "revokeDevice":
                guard let installationID = request.installationID else {
                    return SpacesMobileBridgeControlResponse(ok: false, message: "Missing mobile installation ID.")
                }
                let devices = try revokePairing(installationID: installationID)
                return SpacesMobileBridgeControlResponse(ok: true, message: "Revoked mobile device.", devices: devices)
            case "resetAllPairings":
                try resetPairings()
                _ = try settingsStore.rotateTransportKey()
                advertiser?.stop()
                advertiser = nil
                server = nil
                return SpacesMobileBridgeControlResponse(ok: true, message: "Reset all mobile pairings.", devices: [])
            default: return SpacesMobileBridgeControlResponse(ok: false, message: "Unsupported mobile bridge control command '\(request.command)'.")
            }
        } catch { return SpacesMobileBridgeControlResponse(ok: false, message: String(describing: error)) }
    }

    private func pairedDevices() throws -> [SpacesMobilePairedDevice] {
        if let server { return try server.listPairedDevices() }
        return try SpacesMobilePairingStore().listDevices()
    }

    private func revokePairing(installationID: String) throws -> [SpacesMobilePairedDevice] {
        if let server { return try server.revokePairing(installationID: installationID) }
        let store = try SpacesMobilePairingStore()
        try store.revoke(installationID: installationID)
        return try store.listDevices()
    }

    private func resetPairings() throws { if let server { try server.resetPairingsAndStop() } else { try SpacesMobilePairingStore().removeAll() } }

    private func pairingLinkHost(for status: SpacesMobileBridgeStatus) -> String {
        SpacesMobileBridgeNetworkInterfaces.pairingLinkHost(boundHost: status.host, networkAddresses: status.networkAddresses)
    }

    private func log(_ message: String) {
        fputs("spaces-terminal-service: \(message)\n", stderr)
        fflush(stderr)
    }
}

@MainActor private final class SpacesMobileBridgeBonjourAdvertiser {
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
        let service = NetService(domain: "local.", type: SpacesMobileBridgeDefaults.bonjourServiceType, name: serviceName, port: Int32(port))
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
