import Foundation
import spacesmobilecore

@MainActor public final class SpacesMobileBridgeSupervisor {
    private let settingsStore: SpacesMobileBridgeSettingsStore
    private let environment: [String: String]
    private let restartInterval: TimeInterval

    private var server: SpacesMobileBridgeServer?
    private var advertiser: SpacesMobileBridgeBonjourAdvertiser?
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
        startRestartTimer()
        startBridgeIfNeeded()
    }

    public func stop() {
        isStopped = true
        restartTimer?.invalidate()
        restartTimer = nil
        advertiser?.stop()
        advertiser = nil
        server?.stop()
        server = nil
    }

    public func status() throws -> SpacesMobileBridgeStatus {
        let status = try settingsStore.status()
        return SpacesMobileBridgeStatus(
            host: status.host, port: server?.listeningPort ?? status.port, pairingCode: status.pairingCode,
            bonjourServiceName: status.bonjourServiceName, bonjourServiceType: status.bonjourServiceType, networkAddresses: status.networkAddresses)
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
            let createdServer = try SpacesMobileBridgeServer(host: settings.host, port: settings.port, pairingCode: settings.pairingCode)
            try createdServer.start()
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
