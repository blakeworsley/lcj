/// ResetTimeFormatter.swift — human-readable reset time strings for the menu bar and dropdown.
///
/// Locale and timeZone are injected so the pure functions are fully testable
/// with fixed dates and known locales. App callers use the defaults
/// (.autoupdatingCurrent) so the output respects the user's 12/24-hour setting.

import Foundation

/// Format a reset time for the compact menu bar label (time only, short style).
///
/// Examples: "9:00 PM" (en_US, 12h) / "21:00" (en_GB, 24h).
/// nil → "–:–"
///
/// WHY .timeStyle .short: DateFormatter's .short time style honours the machine's
/// 12/24-hour preference via the current locale — the "j" calendar symbol without
/// needing an explicit format string, and it matches what users see elsewhere in macOS.
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

/// Format a reset time for the dropdown detail rows (weekday + time, e.g. "Mon 9:00 PM").
///
/// Examples: "Thu 9:00 PM" (en_US, 12h) / "Thu 21:00" (en_GB, 24h).
/// nil → "unknown"
///
/// WHY template "EEE j:mm": the "j" symbol picks 12/24h per the locale/system
/// preference (same as .timeStyle .short but with explicit minute precision); EEE
/// gives the abbreviated weekday so weekly resets show which day without a date.
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

/// Format a reset *date* for the compact menu bar (month/day, e.g. "8/31" in
/// en_US, "31/8" where day comes first). nil → "–"
///
/// WHY a date, not a time: the Codex monthly limit resets days or weeks out, so
/// a time-of-day would be noise there — unlike the 5h window, where the time is
/// the whole point. Template "Md" lets the locale pick the day/month order.
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

/// Compact time-until-reset for the menu bar: "38m", "2h14m", "4d9h".
/// nil → "–"; past/imminent → "<1m". Zero sub-units are dropped ("2h", "4d").
///
/// WHY relative here, absolute in the dropdown: "24% left · ↻19m" answers
/// "when do I get more?" without a mental subtraction; the exact date/time is
/// one click away in the dropdown (menuDetailTime).
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

/// Local midnight at the start of the next calendar month — when a
/// month-to-date budget "resets". nil only if the calendar math fails.
public func startOfNextMonth(after now: Date, calendar: Calendar = .current) -> Date? {
    guard let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))
    else { return nil }
    return calendar.date(byAdding: .month, value: 1, to: thisMonth)
}
