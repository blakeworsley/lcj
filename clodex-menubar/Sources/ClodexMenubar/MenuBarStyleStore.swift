/// MenuBarStyleStore.swift — the user's choice of menu bar visual style.
/// Same per-user UserDefaults pattern as the other stores.

import Foundation

/// Visual styles for the status item. raw values are the persisted identifiers.
enum MenuBarStyle: String, CaseIterable {
    case grid       // 2-row grid: gauges + reset time (clusage-style, default)
    case lanes      // Claude lane on top, Codex lane below (grid variant)
    case compact    // single text line, percents tinted by severity
    case rings      // circular gauges
    case bars       // vertical mini bars (current state)
    case dayPulse   // stacked hourly history bars, last 12 hours
    case weekTrend  // stacked daily history bars, last 7 days
    case monthTrend // stacked daily history bars, last 30 days

    var displayName: String {
        switch self {
        case .grid:       return "Grid (gauges + reset time)"
        case .lanes:      return "Split Lanes (Claude / Codex)"
        case .compact:    return "Compact (one line)"
        case .rings:      return "Rings"
        case .bars:       return "Mini Bars"
        case .dayPulse:   return "Today Pulse (hourly bars)"
        case .weekTrend:  return "Week Trend (daily bars)"
        case .monthTrend: return "Month Trend (daily bars)"
        }
    }
}

enum MenuBarStyleStore {
    static let defaultsKey = "menubar_style"

    static func load() -> MenuBarStyle {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let style = MenuBarStyle(rawValue: raw)
        else { return .grid }
        return style
    }

    static func save(_ style: MenuBarStyle) {
        UserDefaults.standard.set(style.rawValue, forKey: defaultsKey)
    }
}
