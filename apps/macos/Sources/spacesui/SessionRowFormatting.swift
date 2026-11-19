import Foundation
import spacesterminalcore

/// The Last active and Size texts of a Sessions row.
enum SessionRowFormatting {
    /// "Just now", "12 min ago", "3 hr ago", "Yesterday", then the date ("Nov 9", with the year once it
    /// is not the current one). An unreadable timestamp shows as empty rather than as a wrong age.
    static func ageText(lastActive: String, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let date = TerminalSessionTimestamp.date(from: lastActive) else { return "" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600)) hr ago" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(
            .abbreviated
        ).day()
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
        return date.formatted(style)
    }

    static func sizeText(bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
