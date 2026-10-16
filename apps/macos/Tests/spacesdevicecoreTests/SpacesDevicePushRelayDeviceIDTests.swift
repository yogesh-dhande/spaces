import Testing

@testable import spacesdevicecore

@Suite struct SpacesDevicePushRelayDeviceIDTests {
    @Test func slugsTheFingerprintAndPortTheWayThePhoneDoes() {
        #expect(SpacesDevicePushRelayDeviceID.make(certificateFingerprint: "AA:BB:cc", port: 7443) == "device-aa-bb-cc-7443")
    }

    @Test func aFullFingerprintIsCutAtFortyEightCharacters() {
        let fingerprint = String(repeating: "ab", count: 32)
        let id = SpacesDevicePushRelayDeviceID.make(certificateFingerprint: fingerprint, port: 7443)
        #expect(id == "device-" + String(repeating: "ab", count: 24))
    }
}
