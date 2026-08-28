/// UsageSnapshot.swift — model + JSON parsing for the claude.ai org-usage endpoint.
/// Ported from mlg87/lcj clusage-menubar (ClusageCore).
///
/// WHY pure functions only (no networking here): ClodexCore is a Foundation-only
/// library target so it can be used by both the app and the test runner without
/// pulling in AppKit or URLSession dependencies.

import Foundation

// MARK: - Model

/// One usage bucket (session / weekly-scoped / weekly-all).
public struct Bucket: Equatable, Sendable {
    /// 0–100, clamped and rounded from the API's `percent` (or `utilization`) field.
    public let percent: Int
    /// Parsed from `resets_at`; nil if absent or unparseable.
    public let resetsAt: Date?
    /// Display label: "5H" | "WEEK" | scoped model display_name uppercased (e.g. "FABLE").
    public let label: String

    public init(percent: Int, resetsAt: Date?, label: String) {
        self.percent = percent
        self.resetsAt = resetsAt
        self.label = label
    }
}

/// Three usage buckets parsed from GET /api/organizations/{orgId}/usage.
public struct UsageSnapshot: Equatable, Sendable {
    /// limits[kind=="session"] or five_hour fallback.
    public let session: Bucket?
    /// limits[kind=="weekly_scoped"]; label from scope.model.display_name ?? "MODEL".
    public let weeklyScoped: Bucket?
    /// limits[kind=="weekly_all"] or seven_day fallback.
    public let weeklyAll: Bucket?

    public init(session: Bucket?, weeklyScoped: Bucket?, weeklyAll: Bucket?) {
        self.session = session
        self.weeklyScoped = weeklyScoped
        self.weeklyAll = weeklyAll
    }

    /// Parse the raw response body. Returns nil on bad_shape.
    ///
    /// Primary source: `limits[]` array, keyed by `kind`.
    /// Fallback: `five_hour`/`seven_day` top-level objects (older response shape).
    /// nil iff BOTH session and weeklyAll are missing after fallback — the headline
    /// bar's absence means the response is unknown.
    public static func parse(_ body: Data) -> UsageSnapshot? {
        guard let doc = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }

        // -- Primary: limits[] --
        if let limits = doc["limits"] as? [[String: Any]], !limits.isEmpty {
            var session: Bucket?
            var weeklyScoped: Bucket?
            var weeklyAll: Bucket?

            for entry in limits {
                guard let kind = entry["kind"] as? String else { continue }
                // JSONSerialization returns NSNumber for all JSON numbers.
                guard let percentNum = entry["percent"] as? NSNumber else { continue }

                let percent = clampPercent(Int(percentNum.doubleValue.rounded()))
                let resetsAt = parseResetDate(entry["resets_at"] as? String)

                switch kind {
                case "session":
                    session = Bucket(percent: percent, resetsAt: resetsAt, label: "5H")
                case "weekly_all":
                    weeklyAll = Bucket(percent: percent, resetsAt: resetsAt, label: "WEEK")
                case "weekly_scoped":
                    // Label from scope.model.display_name; fall back to "MODEL".
                    let displayName: String
                    if let scope = entry["scope"] as? [String: Any],
                       let model = scope["model"] as? [String: Any],
                       let name = model["display_name"] as? String,
                       !name.isEmpty {
                        displayName = name.uppercased()
                    } else {
                        displayName = "MODEL"
                    }
                    weeklyScoped = Bucket(percent: percent, resetsAt: resetsAt, label: displayName)
                default:
                    break
                }
            }

            // bad_shape: neither headline bucket present
            if session == nil && weeklyAll == nil { return nil }
            return UsageSnapshot(session: session, weeklyScoped: weeklyScoped, weeklyAll: weeklyAll)
        }

        // -- Fallback: five_hour / seven_day top-level objects --
        var session: Bucket?
        var weeklyAll: Bucket?

        if let fh = doc["five_hour"] as? [String: Any],
           let utilNum = fh["utilization"] as? NSNumber {
            let percent = clampPercent(Int(utilNum.doubleValue.rounded()))
            let resetsAt = parseResetDate(fh["resets_at"] as? String)
            session = Bucket(percent: percent, resetsAt: resetsAt, label: "5H")
        }

        if let sd = doc["seven_day"] as? [String: Any],
           let utilNum = sd["utilization"] as? NSNumber {
            let percent = clampPercent(Int(utilNum.doubleValue.rounded()))
            let resetsAt = parseResetDate(sd["resets_at"] as? String)
            weeklyAll = Bucket(percent: percent, resetsAt: resetsAt, label: "WEEK")
        }

        if session == nil && weeklyAll == nil { return nil }
        return UsageSnapshot(session: session, weeklyScoped: nil, weeklyAll: weeklyAll)
    }
}

// MARK: - Date parsing

/// Parse an ISO 8601 date string from the API's `resets_at` field.
///
/// WHY strip fractional seconds: the API returns 6-digit fractional seconds
/// (e.g. "2026-07-11T02:00:00.156578+00:00") which ISO8601DateFormatter with
/// .withFractionalSeconds doesn't reliably handle on all OS versions. Strip the
/// fraction first, then parse with .withInternetDateTime (handles timezone offset).
public func parseResetDate(_ iso: String?) -> Date? {
    guard let iso else { return nil }
    // Strip fractional seconds: remove ".<digits>" before the timezone offset.
    let stripped = iso.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime]
    return fmt.date(from: stripped)
}

// MARK: - Severity band

/// Color band for a usage percentage. green <70 · yellow 70–89 · red ≥90.
public enum Band: Equatable, Sendable {
    case ok       // < 70
    case warn     // 70...89
    case critical // >= 90
}

/// Map a clamped percent value (0–100) to a severity band.
public func band(forPercent p: Int) -> Band {
    switch p {
    case ..<70:  return .ok
    case 70..<90: return .warn
    default:     return .critical
    }
}

// MARK: - Menu bar short label

/// Short label for the menu bar grid. The grid uses 7pt labels per cell,
/// so long model names are abbreviated:
/// "5H" → "5H", "WEEK" → "WK", "FABLE" → "F", other models → first two characters.
public func menuBarShortLabel(_ label: String) -> String {
    switch label {
    case "5H":    return "5H"
    case "WEEK":  return "WK"
    case "FABLE": return "F"
    default:
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "–" : String(trimmed.prefix(2)).uppercased()
    }
}

// MARK: - Helpers (internal)

/// Clamp a percent value to 0...100.
func clampPercent(_ v: Int) -> Int { max(0, min(100, v)) }
