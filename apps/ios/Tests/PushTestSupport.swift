#if canImport(UIKit)
    import Foundation
    import UserNotifications
    @testable import SpacesMobile

    @MainActor final class FakePushSystem: PushSystem {
        var status: UNAuthorizationStatus
        var grantsPermission = true
        private(set) var permissionRequests = 0
        private(set) var remoteRegistrations = 0
        private(set) var badges: [Int] = []
        private(set) var removedDeliveredCount = 0

        init(status: UNAuthorizationStatus = .authorized) { self.status = status }

        func authorizationStatus() async -> UNAuthorizationStatus { status }

        func requestAuthorization() async -> Bool {
            permissionRequests += 1
            status = grantsPermission ? .authorized : .denied
            return grantsPermission
        }

        func registerForRemoteNotifications() { remoteRegistrations += 1 }
        func setBadgeCount(_ count: Int) async { badges.append(count) }
        func removeAllDeliveredNotifications() { removedDeliveredCount += 1 }
    }

    /// What the relay and the devices were told, in the order they were told it.
    final class PushEventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [String] = []
        var events: [String] { lock.withLock { _events } }
        func append(_ event: String) { lock.withLock { _events.append(event) } }
    }

    final class FakePushRelay: PushRelayClient, @unchecked Sendable {
        struct Registration: Equatable {
            let apnsToken: String
            let environment: PushEnvironment
            let installID: String
            let deviceIDs: [String]
        }

        private let lock = NSLock()
        private let log: PushEventLog?
        private var _registrations: [Registration] = []
        private var _failRegister = false
        private var issued = 0

        init(log: PushEventLog? = nil) { self.log = log }

        var registrations: [Registration] { lock.withLock { _registrations } }
        var failRegister: Bool {
            get { lock.withLock { _failRegister } }
            set { lock.withLock { _failRegister = newValue } }
        }

        func register(apnsToken: String, environment: PushEnvironment, installID: String, deviceIDs: [String]) async throws -> String {
            // Yields so a caller that does not wait for the relay would let a later step overtake it.
            await Task.yield()
            let capability = try lock.withLock {
                if _failRegister { throw PushRelayClientError.rejected(status: 502) }
                _registrations.append(Registration(apnsToken: apnsToken, environment: environment, installID: installID, deviceIDs: deviceIDs))
                issued += 1
                return "capability-\(issued)"
            }
            log?.append("relay.register \(deviceIDs.joined(separator: ","))")
            return capability
        }
    }

    final class FakePushEndpoint: PushDeviceEndpoint, @unchecked Sendable {
        struct Registration: Equatable {
            let capability: String
            let notifyBlocked: Bool
            let notifyFinished: Bool
        }

        private let lock = NSLock()
        private let name: String
        private let log: PushEventLog?
        private var _registrations: [Registration] = []
        private var _unregisterCount = 0

        init(name: String = "device", log: PushEventLog? = nil) {
            self.name = name
            self.log = log
        }

        var registrations: [Registration] { lock.withLock { _registrations } }
        var unregisterCount: Int { lock.withLock { _unregisterCount } }

        func register(capability: String, notifyBlocked: Bool, notifyFinished: Bool) async throws {
            lock.withLock {
                _registrations.append(Registration(capability: capability, notifyBlocked: notifyBlocked, notifyFinished: notifyFinished))
            }
            log?.append("\(name).register")
        }

        func unregister() async throws {
            lock.withLock { _unregisterCount += 1 }
            log?.append("\(name).unregister")
        }
    }

    /// Polls until `condition` holds, for work a model starts in an unstructured `Task`.
    @MainActor func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
#endif

#if canImport(UIKit)
    extension PushNotificationCoordinator {
        /// A sync where every paired device is also a target, which is every case that is not about an
        /// uncredentialed or just-removed device.
        func sync(installID: String, targets: [PushDeviceTarget]) async {
            await sync(installID: installID, pairedDeviceIDs: targets.map(\.deviceID), targets: targets)
        }
    }
#endif
