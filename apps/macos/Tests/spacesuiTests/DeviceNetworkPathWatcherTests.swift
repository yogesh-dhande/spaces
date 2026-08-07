import Foundation
import Testing

@testable import spacesui

@Suite struct DeviceNetworkPathChangeFilterTests {
    /// The path `NWPathMonitor` delivers on start describes the network the app is already running on,
    /// which every resolver's cached winner was proven against. Reacting to it would re-race every
    /// paired device on launch for no reason.
    @Test func firstObservedPathIsBaselineNotChange() {
        var filter = DeviceNetworkPathChangeFilter()

        #expect(filter.shouldReact(to: snapshot(satisfied: true, interfaces: ["en0"])) == false)
    }

    /// The monitor repeats a path whenever a property Spaces does not read changes, so an unchanged
    /// status and interface set is not a network change.
    @Test func repeatedIdenticalPathIsNotChange() {
        var filter = DeviceNetworkPathChangeFilter()
        _ = filter.shouldReact(to: snapshot(satisfied: true, interfaces: ["en0"]))

        #expect(filter.shouldReact(to: snapshot(satisfied: true, interfaces: ["en0"])) == false)
        #expect(filter.shouldReact(to: snapshot(satisfied: true, interfaces: ["en0"])) == false)
    }

    /// Losing the network and getting it back are both changes: the drop invalidates the proven address,
    /// and the recovery is the moment worth re-racing on.
    @Test func statusChangeInEitherDirectionIsChange() {
        var filter = DeviceNetworkPathChangeFilter()
        _ = filter.shouldReact(to: snapshot(satisfied: true, interfaces: ["en0"]))

        #expect(filter.shouldReact(to: snapshot(satisfied: false, interfaces: ["en0"])) == true)
        #expect(filter.shouldReact(to: snapshot(satisfied: true, interfaces: ["en0"])) == true)
    }

    /// Tailscale coming up or going down leaves the status satisfied throughout and shows only as its
    /// tunnel interface appearing or disappearing, which is exactly the case that changes which of a
    /// device's addresses can be reached.
    @Test func interfaceAppearingOrDisappearingIsChange() {
        var filter = DeviceNetworkPathChangeFilter()
        _ = filter.shouldReact(to: snapshot(satisfied: true, interfaces: ["en0"]))

        #expect(filter.shouldReact(to: snapshot(satisfied: true, interfaces: ["en0", "utun4"])) == true)
        #expect(filter.shouldReact(to: snapshot(satisfied: true, interfaces: ["en0", "utun4"])) == false)
        #expect(filter.shouldReact(to: snapshot(satisfied: true, interfaces: ["en0"])) == true)
    }

    /// Interfaces are compared as a set, so the order the monitor happens to report them in is not a
    /// change on its own.
    @Test func interfaceOrderIsNotChange() {
        var filter = DeviceNetworkPathChangeFilter()
        _ = filter.shouldReact(to: snapshot(satisfied: true, interfaces: ["en0", "utun4"]))

        #expect(filter.shouldReact(to: snapshot(satisfied: true, interfaces: ["utun4", "en0"])) == false)
    }

    /// Switching networks, leaving Wi-Fi for a different interface, is the case the whole re-race
    /// exists for, and it can arrive as a single callback with no unsatisfied path in between.
    @Test func swappingInterfacesIsChange() {
        var filter = DeviceNetworkPathChangeFilter()
        _ = filter.shouldReact(to: snapshot(satisfied: true, interfaces: ["en0"]))

        #expect(filter.shouldReact(to: snapshot(satisfied: true, interfaces: ["en5"])) == true)
    }

    private func snapshot(satisfied: Bool, interfaces: Set<String>) -> DeviceNetworkPathSnapshot {
        DeviceNetworkPathSnapshot(isSatisfied: satisfied, interfaceNames: interfaces)
    }
}
