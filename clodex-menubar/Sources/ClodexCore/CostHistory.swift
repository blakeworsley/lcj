/// CostHistory.swift — time-bucketed cost series for the trend menu bar styles.
///
/// Both scanners (Codex turns, Claude local logs) reduce their data to two
/// small maps: cost per local calendar day and cost per local hour. The view
/// layer asks for the last N buckets ending now and renders them as stacked
/// sparkbars. Keys are plain strings so the maps are Codable for disk caches.

import Foundation

/// Cost per bucket. Day keys: "2026-08-26". Hour keys: "2026-08-26 14".
public struct CostHistory: Equatable, Sendable, Codable {
    public var dailyCost: [String: Double]
    public var hourlyCost: [String: Double]

    public init(dailyCost: [String: Double] = [:], hourlyCost: [String: Double] = [:]) {
        self.dailyCost = dailyCost
        self.hourlyCost = hourlyCost
    }

    public static let empty = CostHistory()

    /// Merge another history into this one (used to combine per-file caches).
    public mutating func merge(_ other: CostHistory) {
        for (k, v) in other.dailyCost { dailyCost[k, default: 0] += v }
        for (k, v) in other.hourlyCost { hourlyCost[k, default: 0] += v }
    }

    /// Sum of daily costs over the last `days` calendar days including today.
    public func total(days: Int, endingAt now: Date, calendar: Calendar = .current) -> Double {
        dayKeys(last: days, endingAt: now, calendar: calendar)
            .reduce(0) { $0 + (dailyCost[$1] ?? 0) }
    }
}

// MARK: - Bucket keys

public func costHistoryDayKey(_ date: Date, calendar: Calendar = .current) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

public func costHistoryHourKey(_ date: Date, calendar: Calendar = .current) -> String {
    let c = calendar.dateComponents([.year, .month, .day, .hour], from: date)
    return String(format: "%04d-%02d-%02d %02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0)
}

/// The last `n` day keys ending at `now`, oldest first.
public func dayKeys(last n: Int, endingAt now: Date, calendar: Calendar = .current) -> [String] {
    let start = calendar.startOfDay(for: now)
    return (0..<n).reversed().compactMap { offset in
        calendar.date(byAdding: .day, value: -offset, to: start)
            .map { costHistoryDayKey($0, calendar: calendar) }
    }
}

/// The last `n` hour keys ending at `now`'s current hour, oldest first.
public func hourKeys(last n: Int, endingAt now: Date, calendar: Calendar = .current) -> [String] {
    var comps = calendar.dateComponents([.year, .month, .day, .hour], from: now)
    comps.minute = 0
    comps.second = 0
    guard let hourStart = calendar.date(from: comps) else { return [] }
    return (0..<n).reversed().compactMap { offset in
        calendar.date(byAdding: .hour, value: -offset, to: hourStart)
            .map { costHistoryHourKey($0, calendar: calendar) }
    }
}

/// Series of values for the given bucket keys (missing buckets are 0).
public func historySeries(_ costByBucket: [String: Double], keys: [String]) -> [Double] {
    keys.map { costByBucket[$0] ?? 0 }
}
