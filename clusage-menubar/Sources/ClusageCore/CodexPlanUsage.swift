/// CodexPlanUsage.swift — model + parsing for ChatGPT's Codex usage endpoint.
///
/// GET https://chatgpt.com/backend-api/wham/usage (the same internal endpoint
/// the ChatGPT Codex usage page calls) reports, for workspaces with spend
/// controls enabled, a monthly per-user credit limit:
///
///   {"plan_type":"business", ...,
///    "spend_control":{"reached":false,"individual_limit":{
///       "source":"workspace_spend_controls",
///       "limit":"4300","used":"3604.34","remaining":"695.65",
///       "used_percent":84,"remaining_percent":16,
///       "reset_after_seconds":380033,"reset_at":1788220801}}}
///
/// This gives Codex a true percent-of-limit gauge, matching how the Claude
/// column works. Note limit/used/remaining are JSON *strings*; percents are
/// numbers; reset_at is epoch seconds. Undocumented internal endpoint (same
/// gray area as the claude.ai usage endpoint) — parse defensively and degrade
/// to the dollar-budget barometer when absent.

import Foundation

/// Monthly credit spend-control state for the signed-in Codex user.
public struct CodexPlanUsage: Equatable, Sendable {
    public let limitCredits: Double
    public let usedCredits: Double
    public let remainingCredits: Double
    /// 0–100 as reported (clamped).
    public let usedPercent: Int
    public let resetsAt: Date?
    /// True when the spend control is currently blocking usage.
    public let reached: Bool

    public init(limitCredits: Double, usedCredits: Double, remainingCredits: Double,
                usedPercent: Int, resetsAt: Date?, reached: Bool) {
        self.limitCredits = limitCredits
        self.usedCredits = usedCredits
        self.remainingCredits = remainingCredits
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.reached = reached
    }

    /// Parse the wham/usage response body. Returns nil when the response has
    /// no spend_control.individual_limit (plans without workspace spend
    /// controls) — callers fall back to the local dollar-budget barometer.
    public static func parse(_ body: Data) -> CodexPlanUsage? {
        guard let doc = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let spend = doc["spend_control"] as? [String: Any],
              let limit = spend["individual_limit"] as? [String: Any]
        else { return nil }

        // limit/used/remaining arrive as strings; be tolerant of numbers too.
        func credits(_ key: String) -> Double? {
            if let s = limit[key] as? String { return Double(s) }
            if let n = limit[key] as? NSNumber { return n.doubleValue }
            return nil
        }
        guard let limitCredits = credits("limit"),
              let usedCredits = credits("used")
        else { return nil }

        let remaining = credits("remaining") ?? max(0, limitCredits - usedCredits)
        let percent: Int
        if let p = limit["used_percent"] as? NSNumber {
            percent = clampPercent(Int(p.doubleValue.rounded()))
        } else if limitCredits > 0 {
            percent = clampPercent(Int((usedCredits / limitCredits * 100).rounded()))
        } else {
            percent = 0
        }

        var resetsAt: Date?
        if let epoch = limit["reset_at"] as? NSNumber {
            resetsAt = Date(timeIntervalSince1970: epoch.doubleValue)
        }

        return CodexPlanUsage(
            limitCredits: limitCredits,
            usedCredits: usedCredits,
            remainingCredits: remaining,
            usedPercent: percent,
            resetsAt: resetsAt,
            reached: (spend["reached"] as? Bool) ?? false)
    }
}
