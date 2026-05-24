import Foundation
import Observation
import spacesmobilecore

struct SpacesMobileDiscoveredBridge: Identifiable, Equatable {
    let serviceName: String
    let host: String
    let port: Int

    var id: String { "\(serviceName)|\(host)|\(port)" }
}

@MainActor @Observable final class SpacesMobileBridgeDiscovery: NSObject, @preconcurrency NetServiceBrowserDelegate,
    @preconcurrency NetServiceDelegate
{
    var discoveredBridges: [SpacesMobileDiscoveredBridge] = []
    var isBrowsing = false

    @ObservationIgnored private let browser = NetServiceBrowser()
    @ObservationIgnored private var servicesByID: [ObjectIdentifier: NetService] = [:]

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        guard !isBrowsing else { return }
        isBrowsing = true
        browser.searchForServices(ofType: SpacesMobileBridgeEndpointDefaults.bonjourServiceType, inDomain: "local.")
    }

    func stop() {
        browser.stop()
        for service in servicesByID.values {
            service.stop()
            service.delegate = nil
        }
        servicesByID.removeAll()
        discoveredBridges.removeAll()
        isBrowsing = false
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        servicesByID[ObjectIdentifier(service)] = service
        service.resolve(withTimeout: 4)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        servicesByID.removeValue(forKey: ObjectIdentifier(service))
        discoveredBridges.removeAll { $0.serviceName == service.name }
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        isBrowsing = false
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        isBrowsing = false
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard sender.port > 0, let hostName = sender.hostName?.trimmingTrailingDot, !hostName.isEmpty else { return }
        let bridge = SpacesMobileDiscoveredBridge(serviceName: sender.name, host: hostName, port: sender.port)
        if let index = discoveredBridges.firstIndex(where: { $0.serviceName == sender.name }) {
            discoveredBridges[index] = bridge
        } else {
            discoveredBridges.append(bridge)
        }
        discoveredBridges.sort { lhs, rhs in
            lhs.serviceName.localizedStandardCompare(rhs.serviceName) == .orderedAscending
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        servicesByID.removeValue(forKey: ObjectIdentifier(sender))
    }
}

private extension String {
    var trimmingTrailingDot: String {
        hasSuffix(".") ? String(dropLast()) : self
    }
}
