import Foundation
import spacesclientcore
import spacesdevicecore
import spacesterminalcore
import workspacecore

#if os(macOS)
    import Darwin

    /// Owns workspace-scoped `ssh -L` forwards and their Caddy route-registry entries for remote browser
    /// sessions. Each running remote workspace gets one SSH process with one local-forward binding per
    /// assigned service port, so browser focus can reuse a preloaded route instead of opening SSH on the
    /// click path. Blocking SSH/Caddy reconciliation runs off the main actor (see `AppKitController`),
    /// while `stopAll` runs synchronously during app termination, so `workspaceForwards` is guarded by
    /// `forwardsLock` and the type is `@unchecked Sendable`.
    final class BrowserSSHForwardManager: @unchecked Sendable {
        struct RoutePlan: Equatable, Sendable {
            let serviceName: String
            let remotePort: Int
            let routeHost: String
            let browserURL: URL
        }

        struct SSHForwardBinding: Equatable, Sendable {
            let localPort: Int
            let remotePort: Int
        }

        private struct WorkspaceKey: Hashable {
            let deviceID: String
            let workspaceID: String
        }

        private struct ServiceDescriptor: Hashable {
            let serviceName: String
            let remotePort: Int
            let routeHost: String
        }

        private struct ServiceForward {
            let descriptor: ServiceDescriptor
            let localPort: Int
            let registryKey: String

            var upstream: String { "127.0.0.1:\(localPort)" }
            var caddyRoute: CaddyRoute { CaddyRoute(host: descriptor.routeHost, upstream: upstream) }
        }

        private struct WorkspaceForward {
            let process: Process
            let services: [ServiceDescriptor: ServiceForward]

            var registryKeys: Set<String> { Set(services.values.map(\.registryKey)) }
            var caddyRoutes: [CaddyRoute] { services.values.map(\.caddyRoute) }

            func service(matching plan: RoutePlan) -> ServiceForward? {
                services[ServiceDescriptor(serviceName: plan.serviceName, remotePort: plan.remotePort, routeHost: plan.routeHost)]
            }

            func matches(_ descriptors: [ServiceDescriptor]) -> Bool {
                Set(services.keys) == Set(descriptors) && process.isRunning && services.values.allSatisfy { Self.canConnect(port: $0.localPort) }
            }

            private static func canConnect(port: Int) -> Bool { BrowserSSHForwardManager.canConnect(port: port) }
        }

        private let forwardsLock = NSLock()
        private var workspaceForwards: [WorkspaceKey: WorkspaceForward] = [:]
        private var deviceRevisions: [String: Int] = [:]

        private func drainForwards() -> [WorkspaceKey: WorkspaceForward] {
            forwardsLock.lock()
            defer { forwardsLock.unlock() }
            let all = workspaceForwards
            workspaceForwards.removeAll()
            deviceRevisions.removeAll()
            return all
        }

        func routedURL(targetURL: String, workspace: SpacesDeviceWorkspaceSummary, device: SpacesPairedDeviceRecord, timeout: TimeInterval = 5) throws
            -> URL
        {
            guard let plan = Self.routePlan(targetURL: targetURL, assignedPorts: workspace.assignedPorts) else {
                guard let url = URL(string: targetURL) else { throw WorkspaceError.invalidArgument(message: "Browser session URL is invalid.") }
                return url
            }
            let forward = try ensureWorkspaceForward(workspace: workspace, device: device, timeout: timeout, revision: nil)
            guard let service = forward.service(matching: plan) else {
                throw WorkspaceError.invalidArgument(message: "Browser session URL no longer matches a workspace service.")
            }
            let configJSON = try waitForCaddyConfig(routeHost: service.descriptor.routeHost, upstream: service.upstream, timeout: timeout)
            let localRouterPort = try Self.routerPort(configJSON: configJSON)
            guard let routedPlan = Self.routePlan(targetURL: targetURL, assignedPorts: workspace.assignedPorts, localRouterPort: localRouterPort)
            else { throw WorkspaceError.invalidArgument(message: "Browser session URL no longer matches a workspace service.") }
            return routedPlan.browserURL
        }

        func reconcile(device: SpacesPairedDeviceRecord, overview: SpacesDeviceOverviewPayload, timeout: TimeInterval = 5, revision: Int? = nil) {
            if let revision { guard recordRevision(deviceID: device.id, revision: revision) else { return } }
            let desiredWorkspaces = overview.workspaces.filter { Self.shouldPreloadForwards(workspace: $0) }
            guard isCurrentRevision(deviceID: device.id, revision: revision) else { return }
            stopWorkspaces(deviceID: device.id, keepingWorkspaceIDs: Set(desiredWorkspaces.map(\.id)), revision: revision)
            for workspace in desiredWorkspaces {
                guard isCurrentRevision(deviceID: device.id, revision: revision) else { return }
                do {
                    let forward = try ensureWorkspaceForward(workspace: workspace, device: device, timeout: timeout, revision: revision)
                    _ = try waitForCaddyConfig(routes: forward.caddyRoutes, timeout: timeout)
                } catch is CancellationError { return } catch {
                    NSLog(
                        "spaces: failed to preload remote browser forwards for \(device.name) workspace \(workspace.displayName): \(String(describing: error))"
                    )
                }
            }
        }

        func stop(deviceID: String, revision: Int? = nil) {
            if let revision { guard recordRevision(deviceID: deviceID, revision: revision) else { return } }
            stopWorkspaces(deviceID: deviceID, keepingWorkspaceIDs: [], revision: revision)
        }

        func stopAll() {
            let active = drainForwards()
            for forward in active.values where forward.process.isRunning { forward.process.terminate() }
            do { try removeRemoteBrowserCaddyRoutes() } catch {
                NSLog("spaces: failed to remove remote browser caddy routes: \(String(describing: error))")
            }
        }

        static func routePlan(targetURL: String, assignedPorts: [SpacesDeviceAssignedPort], localRouterPort: Int? = nil) -> RoutePlan? {
            guard let target = URLComponents(string: targetURL), target.scheme?.lowercased() == "http" else { return nil }
            let targetHost = target.host?.lowercased()
            let targetPort = target.port

            for assignedPort in assignedPorts {
                guard assignedPort.port > 0, let serviceURL = URLComponents(string: assignedPort.url), let routeHost = serviceURL.host,
                    let serviceScheme = serviceURL.scheme, serviceScheme.lowercased() == "http"
                else { continue }
                let servicePort = serviceURL.port
                if targetHost == routeHost.lowercased(), targetPort == servicePort {
                    guard let browserURL = browserURL(serviceURL: serviceURL, targetURL: target, localRouterPort: localRouterPort) else { continue }
                    return RoutePlan(serviceName: assignedPort.name, remotePort: assignedPort.port, routeHost: routeHost, browserURL: browserURL)
                }
                if isLoopbackHost(targetHost), targetPort == assignedPort.port,
                    let browserURL = browserURL(serviceURL: serviceURL, targetURL: target, localRouterPort: localRouterPort)
                {
                    return RoutePlan(serviceName: assignedPort.name, remotePort: assignedPort.port, routeHost: routeHost, browserURL: browserURL)
                }
            }
            return nil
        }

        static func sshArguments(device: SpacesPairedDeviceRecord, localPort: Int, remotePort: Int) throws -> [String] {
            try sshArguments(device: device, bindings: [SSHForwardBinding(localPort: localPort, remotePort: remotePort)])
        }

        static func sshArguments(device: SpacesPairedDeviceRecord, bindings: [SSHForwardBinding]) throws -> [String] {
            guard !bindings.isEmpty else {
                throw WorkspaceError.invalidArgument(message: "Remote browser sessions require at least one SSH forward.")
            }
            guard let sshHost = normalized(device.sshHost) else {
                throw WorkspaceError.invalidArgument(message: "Remote browser sessions require SSH host metadata for \(device.name).")
            }
            let destination = normalized(device.sshUser).map { "\($0)@\(sshHost)" } ?? sshHost
            var arguments = ["-N"]
            for binding in bindings { arguments += ["-L", "127.0.0.1:\(binding.localPort):127.0.0.1:\(binding.remotePort)"] }
            arguments += ["-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-o", "StrictHostKeyChecking=yes"]
            if let sshPort = device.sshPort { arguments += ["-p", String(sshPort)] }
            arguments.append(destination)
            return arguments
        }

        private func ensureWorkspaceForward(
            workspace: SpacesDeviceWorkspaceSummary, device: SpacesPairedDeviceRecord, timeout: TimeInterval, revision: Int?
        ) throws -> WorkspaceForward {
            let key = WorkspaceKey(deviceID: device.id, workspaceID: workspace.id)
            let descriptors = Self.serviceDescriptors(assignedPorts: workspace.assignedPorts)
            guard !descriptors.isEmpty else {
                throw WorkspaceError.invalidArgument(message: "Remote browser sessions require at least one workspace service.")
            }

            let forward: WorkspaceForward
            forwardsLock.lock()
            do {
                if let revision, deviceRevisions[device.id] != revision { throw CancellationError() }
                if let existing = workspaceForwards[key], existing.matches(descriptors) {
                    forward = existing
                } else {
                    if let stale = workspaceForwards.removeValue(forKey: key) { if stale.process.isRunning { stale.process.terminate() } }
                    try removeRemoteBrowserCaddyRoutes(deviceID: key.deviceID, workspaceID: key.workspaceID)
                    forward = try startWorkspaceForwardLocked(descriptors: descriptors, key: key, device: device, timeout: timeout)
                    workspaceForwards[key] = forward
                }
                try publishCaddyRoutes(forward: forward)
                forwardsLock.unlock()
            } catch {
                forwardsLock.unlock()
                throw error
            }

            return forward
        }

        private func recordRevision(deviceID: String, revision: Int) -> Bool {
            forwardsLock.lock()
            defer { forwardsLock.unlock() }
            let current = deviceRevisions[deviceID] ?? 0
            guard revision >= current else { return false }
            deviceRevisions[deviceID] = revision
            return true
        }

        private func isCurrentRevision(deviceID: String, revision: Int?) -> Bool {
            guard let revision else { return true }
            forwardsLock.lock()
            defer { forwardsLock.unlock() }
            return deviceRevisions[deviceID] == revision
        }

        private func startWorkspaceForwardLocked(
            descriptors: [ServiceDescriptor], key: WorkspaceKey, device: SpacesPairedDeviceRecord, timeout: TimeInterval
        ) throws -> WorkspaceForward {
            var usedLocalPorts = Set<Int>()
            var services: [ServiceDescriptor: ServiceForward] = [:]
            for descriptor in descriptors {
                let localPort = try Self.allocateUniqueLocalPort(excluding: usedLocalPorts)
                usedLocalPorts.insert(localPort)
                services[descriptor] = ServiceForward(
                    descriptor: descriptor, localPort: localPort,
                    registryKey: Self.registryKey(deviceID: key.deviceID, workspaceID: key.workspaceID, service: descriptor))
            }

            let bindings = descriptors.compactMap { descriptor -> SSHForwardBinding? in
                guard let service = services[descriptor] else { return nil }
                return SSHForwardBinding(localPort: service.localPort, remotePort: descriptor.remotePort)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = try Self.sshArguments(device: device, bindings: bindings)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()

            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if !process.isRunning { break }
                if services.values.allSatisfy({ Self.canConnect(port: $0.localPort) }) {
                    return WorkspaceForward(process: process, services: services)
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning { process.terminate() }
            throw WorkspaceError.invalidArgument(message: "Timed out opening SSH browser forward for \(device.name).")
        }

        private func publishCaddyRoutes(forward: WorkspaceForward) throws {
            let registryPath = try CaddyService.routeRegistryPath()
            let entries = forward.services.values.sorted { lhs, rhs in
                if lhs.descriptor.serviceName != rhs.descriptor.serviceName { return lhs.descriptor.serviceName < rhs.descriptor.serviceName }
                return lhs.descriptor.remotePort < rhs.descriptor.remotePort
            }.map { CaddyRouteRegistryEntry(key: $0.registryKey, route: $0.caddyRoute) }
            try CaddyRouteRegistry.replace(path: registryPath, removingKeys: [], upserting: entries)
            try IPCNotification.post(IPCNotification.caddyRouteRegistryDidChange)
        }

        private func removeRemoteBrowserCaddyRoutes(deviceID: String? = nil, workspaceID: String? = nil, keepingWorkspaceIDs: Set<String> = []) throws
        {
            let didRemove = try CaddyRouteRegistry.removeWhere(path: try CaddyService.routeRegistryPath()) { entry in
                guard entry.key.hasPrefix(Self.registryKeyPrefix) else { return false }
                guard let deviceID else { return true }
                guard entry.key.hasPrefix(Self.registryDevicePrefix(deviceID: deviceID)) else { return false }
                if let workspaceID { return entry.key.hasPrefix(Self.registryWorkspacePrefix(deviceID: deviceID, workspaceID: workspaceID)) }
                return !keepingWorkspaceIDs.contains(where: { workspaceID in
                    entry.key.hasPrefix(Self.registryWorkspacePrefix(deviceID: deviceID, workspaceID: workspaceID))
                })
            }
            if didRemove { try IPCNotification.post(IPCNotification.caddyRouteRegistryDidChange) }
        }

        private func stopWorkspaces(deviceID: String, keepingWorkspaceIDs: Set<String>, revision: Int?) {
            forwardsLock.lock()
            do {
                if let revision, deviceRevisions[deviceID] != revision {
                    forwardsLock.unlock()
                    return
                }
                let staleKeys = workspaceForwards.keys.filter { $0.deviceID == deviceID && !keepingWorkspaceIDs.contains($0.workspaceID) }
                let removed = staleKeys.compactMap { workspaceForwards.removeValue(forKey: $0) }
                for forward in removed where forward.process.isRunning { forward.process.terminate() }
                try removeRemoteBrowserCaddyRoutes(deviceID: deviceID, keepingWorkspaceIDs: keepingWorkspaceIDs)
                forwardsLock.unlock()
            } catch {
                forwardsLock.unlock()
                NSLog("spaces: failed to remove remote browser caddy routes: \(String(describing: error))")
            }
        }

        private func waitForCaddyConfig(routes: [CaddyRoute], timeout: TimeInterval) throws -> Data {
            guard !routes.isEmpty else { return Data() }
            return try waitForCaddyConfig(
                routeMatches: routes.map { (host: $0.host, upstream: $0.upstream) }, timeout: timeout,
                timeoutMessage: "Timed out waiting for the local Caddy router to load remote workspace services.")
        }

        private func waitForCaddyConfig(routeHost: String, upstream: String, timeout: TimeInterval) throws -> Data {
            try waitForCaddyConfig(
                routeMatches: [(host: routeHost, upstream: upstream)], timeout: timeout,
                timeoutMessage: "Timed out waiting for the local Caddy router to load \(routeHost).")
        }

        private func waitForCaddyConfig(routeMatches: [(host: String, upstream: String)], timeout: TimeInterval, timeoutMessage: String) throws
            -> Data
        {
            let configPath = try CaddyService.configFilePath()
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)), let config = String(data: data, encoding: .utf8),
                    routeMatches.allSatisfy({ config.contains("\"\($0.host)\"") && config.contains("\"\($0.upstream)\"") })
                {
                    return data
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            throw WorkspaceError.invalidArgument(message: timeoutMessage)
        }

        private static func shouldPreloadForwards(workspace: SpacesDeviceWorkspaceSummary) -> Bool {
            guard !serviceDescriptors(assignedPorts: workspace.assignedPorts).isEmpty else { return false }
            return workspace.isRunning || workspace.processRows.contains { $0.runState == .running }
                || workspace.codingAgentRows.contains { $0.runState == .running } || workspace.terminalRows.contains { $0.runState == .running }
        }

        private static func serviceDescriptors(assignedPorts: [SpacesDeviceAssignedPort]) -> [ServiceDescriptor] {
            var seen = Set<ServiceDescriptor>()
            var descriptors: [ServiceDescriptor] = []
            for assignedPort in assignedPorts {
                guard assignedPort.port > 0, let serviceURL = URLComponents(string: assignedPort.url), let routeHost = serviceURL.host,
                    serviceURL.scheme?.lowercased() == "http"
                else { continue }
                let descriptor = ServiceDescriptor(serviceName: assignedPort.name, remotePort: assignedPort.port, routeHost: routeHost)
                guard seen.insert(descriptor).inserted else { continue }
                descriptors.append(descriptor)
            }
            return descriptors.sorted { lhs, rhs in
                if lhs.serviceName != rhs.serviceName { return lhs.serviceName < rhs.serviceName }
                if lhs.remotePort != rhs.remotePort { return lhs.remotePort < rhs.remotePort }
                return lhs.routeHost < rhs.routeHost
            }
        }

        private static func registryKey(deviceID: String, workspaceID: String, service: ServiceDescriptor) -> String {
            "\(registryWorkspacePrefix(deviceID: deviceID, workspaceID: workspaceID))\(service.serviceName):\(service.remotePort)"
        }

        private static let registryKeyPrefix = "remote-browser:"

        private static func registryDevicePrefix(deviceID: String) -> String { "\(registryKeyPrefix)\(deviceID):" }

        private static func registryWorkspacePrefix(deviceID: String, workspaceID: String) -> String {
            "\(registryDevicePrefix(deviceID: deviceID))\(workspaceID):"
        }

        private static func browserURL(serviceURL: URLComponents, targetURL: URLComponents, localRouterPort: Int?) -> URL? {
            var routed = serviceURL
            if let localRouterPort { routed.port = localRouterPort }
            routed.path = targetURL.path.isEmpty ? "/" : targetURL.path
            routed.query = targetURL.query
            routed.fragment = targetURL.fragment
            return routed.url
        }

        private static func routerPort(configJSON: Data) throws -> Int {
            guard let root = try JSONSerialization.jsonObject(with: configJSON) as? [String: Any], let apps = root["apps"] as? [String: Any],
                let http = apps["http"] as? [String: Any], let servers = http["servers"] as? [String: Any],
                let spaces = servers["spaces"] as? [String: Any], let listen = spaces["listen"] as? [String], let first = listen.first,
                let portSubstring = first.split(separator: ":").last, let port = Int(portSubstring)
            else { throw WorkspaceError.invalidArgument(message: "Local Caddy router port is unavailable.") }
            return port
        }

        private static func isLoopbackHost(_ host: String?) -> Bool {
            guard let host else { return false }
            return host == "localhost" || host == "127.0.0.1" || host == "::1"
        }

        private static func normalized(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            return trimmed
        }

        private static func allocateUniqueLocalPort(excluding usedPorts: Set<Int>) throws -> Int {
            for _ in 0..<20 {
                let port = try allocateLocalPort()
                if !usedPorts.contains(port) { return port }
            }
            throw WorkspaceError.invalidArgument(message: "Unable to allocate unique local ports for remote browser forwarding.")
        }

        private static func allocateLocalPort() throws -> Int {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            defer { close(descriptor) }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            let bindResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bindResult == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

            var boundAddress = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
            }
            guard nameResult == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            return Int(UInt16(bigEndian: boundAddress.sin_port))
        }

        private static func canConnect(port: Int) -> Bool {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { return false }
            defer { close(descriptor) }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            } == 0
        }
    }
#endif
