#if canImport(Darwin)
    import Darwin
    import Dispatch
    import Foundation
    import XCTest

    @testable import spacesdeviceapi

    /// `SpacesDeviceAPIControlServer` and `DeviceOverviewStreamServer` each own a listening Unix-socket
    /// descriptor closed from their dispatch source's cancel handler. Both are singletons restarted in
    /// place by `SpacesDeviceAPISupervisor` (stop, drop the reference, then start a fresh instance on the
    /// same profile-scoped socket path), which is exactly the shape that orphans a descriptor if the
    /// cancel handler reaches back through a `[weak self]` that has already gone nil (see #306). These
    /// tests drop the owning server immediately after `stop()` and assert dispatch still closes the
    /// descriptor, mirroring `SessionSocketDescriptorLifetimeTests` in spacesterminalghosttyTests.
    final class AcceptSourceDescriptorLifetimeTests: XCTestCase {
        func testStoppingDeviceAPIControlServerReleasesItsDescriptorAfterTheServerIsDropped() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let socketPath = root.appendingPathComponent("control.sock").path
            let queue = DispatchQueue(label: "accept-source-descriptor-lifetime-test-control")

            var server: SpacesDeviceAPIControlServer? = SpacesDeviceAPIControlServer(socketPath: socketPath, queue: queue) { _ in
                SpacesDeviceAPIControlResponse(ok: true, message: "ack")
            }
            try server?.start()
            XCTAssertEqual(Self.openDescriptorCount(forSocketPaths: [socketPath]), 1)
            server?.stop()
            server = nil

            try await waitUntil(timeout: 10) { Self.openDescriptorCount(forSocketPaths: [socketPath]) == 0 }
        }

        func testStoppingDeviceOverviewStreamServerReleasesItsDescriptorAfterTheServerIsDropped() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let socketPath = root.appendingPathComponent("overview.sock").path
            let queue = DispatchQueue(label: "accept-source-descriptor-lifetime-test-overview")

            var server: DeviceOverviewStreamServer? = DeviceOverviewStreamServer(socketPath: socketPath, queue: queue) { nil }
            try server?.start()
            XCTAssertEqual(Self.openDescriptorCount(forSocketPaths: [socketPath]), 1)
            server?.stop()
            server = nil

            try await waitUntil(timeout: 10) { Self.openDescriptorCount(forSocketPaths: [socketPath]) == 0 }
        }

        /// How many descriptors this process holds on Unix sockets bound to `socketPaths`. Reads the
        /// kernel's own descriptor table rather than the filesystem, so it still sees a descriptor whose
        /// socket file was unlinked at teardown — which is exactly the leaked state being asserted against.
        private static func openDescriptorCount(forSocketPaths socketPaths: [String]) -> Int {
            let pid = getpid()
            let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bufferSize > 0 else { return 0 }
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufferSize) / MemoryLayout<proc_fdinfo>.stride)
            let usedBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, bufferSize)
            guard usedBytes > 0 else { return 0 }

            let wanted = Set(socketPaths)
            var matches = 0
            for descriptor in descriptors.prefix(Int(usedBytes) / MemoryLayout<proc_fdinfo>.stride)
            where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var socketInfo = socket_fdinfo()
                let read = proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socketInfo, Int32(MemoryLayout<socket_fdinfo>.size))
                guard read > 0, socketInfo.psi.soi_family == AF_UNIX else { continue }
                let address = socketInfo.psi.soi_proto.pri_un.unsi_addr.ua_sun
                let boundPath = withUnsafePointer(to: address.sun_path) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: address.sun_path)) { String(cString: $0) }
                }
                if wanted.contains(boundPath) { matches += 1 }
            }
            return matches
        }

        private func waitUntil(
            timeout: TimeInterval, pollInterval: TimeInterval = 0.02, file: StaticString = #filePath, line: UInt = #line,
            _ condition: @escaping @Sendable () -> Bool
        ) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return }
                try? await Task.sleep(for: .seconds(pollInterval))
            }
            XCTFail("Timed out waiting for the accept source's descriptor to be released.", file: file, line: line)
            throw NSError(domain: "AcceptSourceDescriptorLifetimeTests", code: 1)
        }
    }
#endif
