import Foundation

/// One flat Alerts-tab row: an attention event or a failed/timed-out automation-run alert. The two kinds
/// merge into a single newest-first list (`SpacesMobileAlertItems.merge`) rather than living in separate
/// sections, matching the Mac's own combined Alerts table.
enum SpacesMobileAlertItem: Identifiable, Equatable {
    case event(SpacesMobileAttentionEvent)
    case automation(SpacesMobileAutomationAlertEntry)

    var id: String {
        switch self {
        case .event(let event): "event:\(event.id)"
        case .automation(let entry): "automation:\(entry.id)"
        }
    }

    /// Nil only for an automation alert whose run the daemon reported neither an end nor a start time
    /// for; an attention event always has one.
    var date: Date? {
        switch self {
        case .event(let event): event.date
        case .automation(let entry): entry.date
        }
    }

    var isDeviceOffline: Bool {
        switch self {
        case .event(let event): event.isDeviceOffline
        case .automation(let entry): entry.isDeviceOffline
        }
    }
}

enum SpacesMobileAlertItems {
    /// Merges attention events and automation alerts into one newest-first list. A nil date sorts last,
    /// matching the nil-last rule each source already sorts itself by.
    static func merge(events: [SpacesMobileAttentionEvent], automationAlerts: [SpacesMobileAutomationAlertEntry]) -> [SpacesMobileAlertItem] {
        let items = events.map(SpacesMobileAlertItem.event) + automationAlerts.map(SpacesMobileAlertItem.automation)
        return items.sorted { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case (let a?, let b?): return a > b
            case (nil, _): return false
            case (_, nil): return true
            }
        }
    }
}
