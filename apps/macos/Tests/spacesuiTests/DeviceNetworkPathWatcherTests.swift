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

    /// The case status and interfaces alone cannot see: moving between two Wi-Fi networks, or waking on a
    /// different one, keeps the path satisfied over the same `en0` while every address on the far side
    /// changes. A different network is reached through a different router, so the gateway is what marks it.
    @Test func sameInterfacesReachedThroughADifferentGatewayIsChange() {
        var filter = DeviceNetworkPathChangeFilter()
        _ = filter.shouldReact(to: snapshot(satisfied: true, interfaces: ["en0"], gateways: ["192.168.1.1"]))

        #expect(filter.shouldReact(to: snapshot(satisfied: true, interfaces: ["en0"], gateways: ["10.0.0.1"])) == true)
    }

    /// Staying on the same network is not a change, however often the monitor repeats the path.
    @Test func sameInterfacesAndSameGatewayIsNotChange() {
        var filter = DeviceNetworkPathChangeFilter()
        _ = filter.shouldReact(to: snapshot(satisfied: true, interfaces: ["en0"], gateways: ["192.168.1.1"]))

        #expect(filter.shouldReact(to: snapshot(satisfied: true, interfaces: ["en0"], gateways: ["192.168.1.1"])) == false)
    }

    /// Gaining or losing a gateway counts too, and the first path observed stays the baseline whatever
    /// its gateways are.
    @Test func gatewaySetGrowingOrShrinkingIsChange() {
        var filter = DeviceNetworkPathChangeFilter()

        #expect(filter.shouldReact(to: snapshot(satisfied: true, interfaces: ["en0"], gateways: ["192.168.1.1"])) == false)
        #expect(filter.shouldReact(to: snapshot(satisfied: true, interfaces: ["en0"], gateways: ["192.168.1.1", "fe80::1"])) == true)
        #expect(filter.shouldReact(to: snapshot(satisfied: true, interfaces: ["en0"], gateways: ["fe80::1", "192.168.1.1"])) == false)
        #expect(filter.shouldReact(to: snapshot(satisfied: true, interfaces: ["en0"], gateways: [])) == true)
    }

    /// The case no comparison can see: a Mac that sleeps on one network and wakes on another comes back
    /// on the same interface, and two routers both being `192.168.1.1` is common enough that the gateway
    /// does not separate them either. Every observable fact is identical, so the wake itself is the
    /// signal.
    @Test func wakeIsAChangeEvenWhenThePathLooksIdentical() {
        var filter = DeviceNetworkPathChangeFilter()
        let home = snapshot(satisfied: true, interfaces: ["en0"], gateways: ["192.168.1.1"])
        _ = filter.shouldReact(to: home)
        #expect(filter.shouldReact(to: home) == false)

        #expect(filter.shouldReactToWake() == true)
    }

    /// Waking drops the baseline, so the path the monitor reports right after a wake re-baselines instead
    /// of firing a second time for the same event.
    @Test func thePathObservedAfterAWakeIsABaselineNotASecondTrigger() {
        var filter = DeviceNetworkPathChangeFilter()
        _ = filter.shouldReact(to: snapshot(satisfied: true, interfaces: ["en0"], gateways: ["192.168.1.1"]))
        _ = filter.shouldReactToWake()

        // Whatever the machine comes back on, satisfied or not, the first path after the wake is only a
        // baseline.
        #expect(filter.shouldReact(to: snapshot(satisfied: false, interfaces: [], gateways: [])) == false)
        // Comparison resumes from there.
        #expect(filter.shouldReact(to: snapshot(satisfied: true, interfaces: ["en0"], gateways: ["10.0.0.1"])) == true)
    }

    private func snapshot(satisfied: Bool, interfaces: Set<String>, gateways: Set<String> = []) -> DeviceNetworkPathSnapshot {
        DeviceNetworkPathSnapshot(isSatisfied: satisfied, interfaceNames: interfaces, gateways: gateways)
    }
}
