/// ResetTimeFormatter.swift — human-readable reset time strings for the menu bar and dropdown.
/// Ported from mlg87/lcj clusage-menubar.
///
/// Locale and timeZone are injected so the pure functions are fully testable
/// with fixed dates and known locales. App callers use the defaults
/// (.autoupdatingCurrent) so the output respects the user's 12/24-hour setting.

import Foundation

/// Format a reset time for the compact menu bar label (time only, short style).
/// Examples: "9:00 PM" (en_US, 12h) / "21:00" (en_GB, 24h). nil → "–:–"
public func menuBarTime(
    _ date: Date?,
    locale: Locale = .autoupdatingCurrent,
    timeZone: TimeZone = .current
) -> String {
    guard let date else { return "–:–" }
    let fmt = DateFormatter()
    fmt.locale = locale
    fmt.timeZone = timeZone
    fmt.dateStyle = .none
    fmt.timeStyle = .short
    return fmt.string(from: date)
}

/// Format a reset *date* for the compact menu bar (month/day, e.g. "8/31" in
/// en_US, "31/8" where day comes first) — used for monthly resets that are days
/// away, where a time-of-day would be noise. nil → "–"
public func menuBarShortDate(
    _ date: Date?,
    locale: Locale = .autoupdatingCurrent,
    timeZone: TimeZone = .current
) -> String {
    guard let date else { return "–" }
    let fmt = DateFormatter()
    fmt.locale = locale
    fmt.timeZone = timeZone
    fmt.setLocalizedDateFormatFromTemplate("Md")
    return fmt.string(from: date)
}

/// Compact time-from-now countdown for the menu bar: "38m", "2h14m", "4d9h".
/// nil → "–"; past/imminent → "<1m". Zero sub-units are dropped ("2h", "4d").
public func menuBarCountdown(to date: Date?, from now: Date = Date()) -> String {
    guard let date else { return "–" }
    let seconds = date.timeIntervalSince(now)
    guard seconds >= 60 else { return "<1m" }
    let totalMinutes = Int(seconds / 60)
    let days = totalMinutes / (24 * 60)
    let hours = (totalMinutes % (24 * 60)) / 60
    let minutes = totalMinutes % 60
    if days > 0 {
        return hours > 0 ? "\(days)d\(hours)h" : "\(days)d"
    }
    if hours > 0 {
        return minutes > 0 ? "\(hours)h\(minutes)m" : "\(hours)h"
    }
    return "\(minutes)m"
}

/// Format a reset time for the dropdown detail rows (weekday + time, e.g. "Mon 9:00 PM").
/// Examples: "Thu 9:00 PM" (en_US, 12h) / "Thu 21:00" (en_GB, 24h). nil → "unknown"
public func menuDetailTime(
    _ date: Date?,
    locale: Locale = .autoupdatingCurrent,
    timeZone: TimeZone = .current
) -> String {
    guard let date else { return "unknown" }
    let fmt = DateFormatter()
    fmt.locale = locale
    fmt.timeZone = timeZone
    fmt.setLocalizedDateFormatFromTemplate("EEE j:mm")
    return fmt.string(from: date)
}
