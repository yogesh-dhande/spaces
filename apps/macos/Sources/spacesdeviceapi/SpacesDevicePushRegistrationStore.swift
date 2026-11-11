import Foundation

/// Where the Device API server keeps and reads phones' push registrations. The pairing store is the
/// production implementation, so a registration lives and dies with its pairing record.
protocol SpacesDevicePushRegistrationStore: Sendable {
    func pushRegistrations() throws -> [String: SpacesDevicePushRegistration]
    func setPushRegistration(_ registration: SpacesDevicePushRegistration, forInstallationID installationID: String) throws
    func clearPushRegistration(forInstallationID installationID: String, matchingCapability: String?) throws -> SpacesDevicePushRegistration?
}
