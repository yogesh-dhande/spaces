#if canImport(UIKit)
    import Foundation
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile

    /// A stand-in for a device's daemon that applies the three alert commands the way the real one does
    /// (a dismissal is recorded only for a current alert candidate, a `comebacklater:` key clears the
    /// flag) and answers each with its refreshed overview. Visits are only recorded: what a daemon clears
    /// on a visit, among the keys the request names, is the daemon's own tested behavior.
    final class FakeAlertDevice: @unchecked Sendable {
        static let flaggedAt = "2026-01-01T09:00:00Z"

        private let lock = NSLock()
        private var overview: SpacesDeviceOverviewPayload
        private var recorded: [Command] = []
        /// When false, requests are recorded but the overview comes back unchanged, as if the device had
        /// not applied them yet.
        var appliesRequests = true

        enum Command: Equatable {
            case dismissAlerts([String])
            case visit(sessionID: String, focusedForSeconds: Double, keys: [String])
            case setComeBackLater(rowKind: SpacesDeviceComeBackLaterRowKind, rowID: String, isOn: Bool)
        }

        init(overview: SpacesDeviceOverviewPayload) { self.overview = overview }

        var currentOverview: SpacesDeviceOverviewPayload { lock.withLock { overview } }
        var commands: [Command] { lock.withLock { recorded } }

        func setOverview(_ overview: SpacesDeviceOverviewPayload) { lock.withLock { self.overview = overview } }

        func client(settings: SpacesMobileConnectionSettings = SpacesMobileConnectionSettings()) -> SpacesDeviceAPIClient {
            SpacesDeviceAPIClient(settings: settings) { [self] request in respond(to: request) }
        }

        private func respond(to request: SpacesDeviceAPIRequest) -> SpacesDeviceAPIResponse {
            lock.withLock {
                switch request.command {
                case .dismissAlerts(let payload):
                    recorded.append(.dismissAlerts(payload.keys))
                    guard appliesRequests else { break }
                    let candidateKeys = Set(overview.alertCandidates().map(\.key))
                    var dismissed = overview.dismissedAlertKeys
                    var flags = overview.comeBackLaterFlags
                    for key in payload.keys {
                        if let reference = SpacesDeviceComeBackLaterFlag.rowReference(fromAlertKey: key) {
                            flags.removeAll { $0.rowKind == reference.rowKind && $0.rowID == reference.rowID }
                        } else if candidateKeys.contains(key), !dismissed.contains(key) {
                            dismissed.append(key)
                        }
                    }
                    overview = overview.replacingAlertState(dismissedAlertKeys: dismissed, comeBackLaterFlags: flags)
                case .setComeBackLater(let payload):
                    recorded.append(.setComeBackLater(rowKind: payload.rowKind, rowID: payload.rowID, isOn: payload.isOn))
                    guard appliesRequests else { break }
                    var flags = overview.comeBackLaterFlags.filter { !($0.rowKind == payload.rowKind && $0.rowID == payload.rowID) }
                    if payload.isOn {
                        flags.append(SpacesDeviceComeBackLaterFlag(rowKind: payload.rowKind, rowID: payload.rowID, flaggedAt: Self.flaggedAt))
                    }
                    overview = overview.replacingAlertState(dismissedAlertKeys: overview.dismissedAlertKeys, comeBackLaterFlags: flags)
                case .visitTerminalSession(let payload):
                    recorded.append(.visit(sessionID: payload.sessionID, focusedForSeconds: payload.focusedForSeconds, keys: payload.keys))
                default: break
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
            }
        }
    }

    extension SpacesDeviceOverviewPayload {
        func replacingAlertState(dismissedAlertKeys: [String], comeBackLaterFlags: [SpacesDeviceComeBackLaterFlag]) -> SpacesDeviceOverviewPayload {
            SpacesDeviceOverviewPayload(
                projects: projects, workspaces: workspaces, sessions: sessions, retainedTerminalSessionIDs: retainedTerminalSessionIDs,
                workspaceIDsWithTeardownInFlight: workspaceIDsWithTeardownInFlight, daemonStatus: daemonStatus, automations: automations,
                automationRuns: automationRuns, dismissedAlertKeys: dismissedAlertKeys, comeBackLaterFlags: comeBackLaterFlags)
        }
    }
#endif
