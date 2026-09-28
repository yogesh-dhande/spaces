// spacesdevicecore also compiles into the Linux daemon, which never renders an Alerts pane, so this
// client-only formatter is compiled out there (matches AutomationRunFormatting.swift's guard).
#if !os(Linux)

    import Foundation

    /// The "how old is this alert" phrasing both clients show next to an alert row, so a Mac and a phone
    /// looking at the same alert print the same age. Callers refresh it on a slow beat rather than on every
    /// overview tick, since only the clock moving (not new device state) changes this text.
    public enum AlertsAgeFormatting {
        /// Abbreviated relative age for an alert row: "now" under a minute, then "5m", "3h", "2d".
        public static func abbreviatedAge(of date: Date, relativeTo now: Date = Date()) -> String {
            let seconds = now.timeIntervalSince(date)
            guard seconds >= 60 else { return "now" }
            let minutes = Int(seconds / 60)
            guard minutes >= 60 else { return "\(minutes)m" }
            let hours = minutes / 60
            guard hours >= 24 else { return "\(hours)h" }
            return "\(hours / 24)d"
        }
    }

#endif
