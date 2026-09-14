/// CodexUsage.swift — pure parsing + aggregation for Codex CLI session logs.
///
/// Codex (OpenAI's CLI/desktop agent) writes one JSONL rollout file per session under
/// ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl. Each turn appends event lines:
///
///   {"type":"turn_context","payload":{"model":"gpt-5.6-luna", ...}}      ← model for
///   {"type":"event_msg","payload":{"type":"token_count","info":{           following turns
///     "total_token_usage": {...cumulative for the session...},
///     "last_token_usage":  {"input_tokens":N,"cached_input_tokens":N,
///                           "output_tokens":N,"total_tokens":N}, ...},
///     "rate_limits":{"primary":null,"secondary":null,
///                    "credits":{"has_credits":true,"balance":null}, ...}}
///
/// `last_token_usage` is the per-turn delta (verified: the deltas sum to
/// `total_token_usage`), so summing it across events gives tokens used in any
/// time window regardless of session boundaries.
///
/// WHY local files, not an API: on business/credit plans Codex exposes no
/// 5h/weekly percent windows (rate_limits.primary/secondary are null), so
/// token volume from local logs is the honest usage signal available. The
/// monthly spend-control gauge (CodexPlanUsage) layers on top when reported.
///
/// WHY in ClusageCore: pure Foundation so ClusageTests can exercise the parser
/// and aggregation without AppKit or filesystem access (same rule as UsageSnapshot).

import Foundation

// MARK: - Model

/// Token usage for one Codex turn (one `token_count` event line).
/// Codable so the app can persist parsed turns to a disk cache between launches.
public struct CodexTurn: Equatable, Sendable, Codable {
    public let timestamp: Date
    public let inputTokens: Int          // includes cachedInputTokens
    public let cachedInputTokens: Int
    public let outputTokens: Int
    public let totalTokens: Int          // input + output
    /// From the preceding turn_context line; nil when the session never named one.
    public let model: String?

    public init(timestamp: Date, inputTokens: Int, cachedInputTokens: Int,
                outputTokens: Int, totalTokens: Int, model: String? = nil) {
        self.timestamp = timestamp
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.model = model
    }
}

/// Plan/limit flags mirrored from the newest `rate_limits` payload seen.
/// On business/credit plans everything interesting is null today; these fields
/// exist so the app starts surfacing limits the moment the backend reports them.
public struct CodexLimitStatus: Equatable, Sendable, Codable {
    public let planType: String?
    public let hasCredits: Bool?
    /// Reported credit balance — null in every observed log; shown if it appears.
    public let creditBalance: Double?
    public let spendControlReached: Bool?
    public let rateLimitReachedType: String?
    /// primary window used_percent, if the backend ever populates it.
    public let primaryUsedPercent: Int?

    public init(planType: String?, hasCredits: Bool?, creditBalance: Double?,
                spendControlReached: Bool?, rateLimitReachedType: String?,
                primaryUsedPercent: Int?) {
        self.planType = planType
        self.hasCredits = hasCredits
        self.creditBalance = creditBalance
        self.spendControlReached = spendControlReached
        self.rateLimitReachedType = rateLimitReachedType
        self.primaryUsedPercent = primaryUsedPercent
    }

    /// True when any signal says usage is being blocked or capped right now.
    public var isLimited: Bool {
        if spendControlReached == true { return true }
        if rateLimitReachedType != nil { return true }
        if hasCredits == false { return true }
        return false
    }
}

/// Per-model rollup over the 7-day window, for the dropdown breakdown.
public struct CodexModelUsage: Equatable, Sendable {
    public let model: String
    public let totalTokens: Int
    public let cost: Double

    public init(model: String, totalTokens: Int, cost: Double) {
        self.model = model
        self.totalTokens = totalTokens
        self.cost = cost
    }
}

/// Aggregated Codex usage over the scan window.
public struct CodexSummary: Equatable, Sendable {
    public let todayTotal: Int
    public let todayOutput: Int
    public let todayCost: Double
    public let last7DaysTotal: Int
    public let last7DaysOutput: Int
    public let last7DaysCost: Double
    /// Rolling 30-day window including today.
    public let last30DaysTotal: Int
    public let last30DaysCost: Double
    /// Calendar month-to-date — the budget barometer number.
    public let monthToDateTotal: Int
    public let monthToDateCost: Double
    /// 7-day per-model rollup, sorted by cost descending.
    public let perModel: [CodexModelUsage]
    /// Distinct session files that produced turns today.
    public let sessionsToday: Int
    /// Newest turn timestamp seen, nil when no turns parsed.
    public let lastActivity: Date?
    /// From the newest rate_limits payload in the window, nil when none seen.
    public let limitStatus: CodexLimitStatus?

    public init(todayTotal: Int, todayOutput: Int, todayCost: Double,
                last7DaysTotal: Int, last7DaysOutput: Int, last7DaysCost: Double,
                last30DaysTotal: Int, last30DaysCost: Double,
                monthToDateTotal: Int, monthToDateCost: Double,
                perModel: [CodexModelUsage], sessionsToday: Int,
                lastActivity: Date?, limitStatus: CodexLimitStatus?) {
        self.todayTotal = todayTotal
        self.todayOutput = todayOutput
        self.todayCost = todayCost
        self.last7DaysTotal = last7DaysTotal
        self.last7DaysOutput = last7DaysOutput
        self.last7DaysCost = last7DaysCost
        self.last30DaysTotal = last30DaysTotal
        self.last30DaysCost = last30DaysCost
        self.monthToDateTotal = monthToDateTotal
        self.monthToDateCost = monthToDateCost
        self.perModel = perModel
        self.sessionsToday = sessionsToday
        self.lastActivity = lastActivity
        self.limitStatus = limitStatus
    }

    public static let empty = CodexSummary(
        todayTotal: 0, todayOutput: 0, todayCost: 0,
        last7DaysTotal: 0, last7DaysOutput: 0, last7DaysCost: 0,
        last30DaysTotal: 0, last30DaysCost: 0,
        monthToDateTotal: 0, monthToDateCost: 0,
        perModel: [], sessionsToday: 0, lastActivity: nil, limitStatus: nil)
}

// MARK: - Line parsing

/// Parse one JSONL line into a CodexTurn. Returns nil for any line that is not a
/// well-formed `token_count` event (cheap substring pre-filter belongs in the caller).
/// `model` is stamped by the caller from the most recent turn_context line.
public func parseCodexTokenCountLine(_ line: String, model: String? = nil) -> CodexTurn? {
    parseCodexLine(line, model: model)?.turn
}

/// Extract the model name from a `turn_context` line ("payload.model") or a
/// `session_meta` line ("payload.base_instructions.provenance.model" — the only
/// model reference in ambient Codex Desktop sessions, which never write a
/// turn_context). Returns nil for any other line shape.
public func parseCodexModelLine(_ line: String) -> String? {
    guard let data = line.data(using: .utf8),
          let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let payload = doc["payload"] as? [String: Any]
    else { return nil }

    switch doc["type"] as? String {
    case "turn_context":
        if let model = payload["model"] as? String, !model.isEmpty { return model }
    case "session_meta":
        if let model = payload["model"] as? String, !model.isEmpty { return model }
        if let bi = payload["base_instructions"] as? [String: Any],
           let prov = bi["provenance"] as? [String: Any],
           let model = prov["model"] as? String, !model.isEmpty {
            return model
        }
    default:
        break
    }
    return nil
}

/// Extract plan/limit flags from a `token_count` line's rate_limits payload.
/// Returns nil when the line has no rate_limits object.
public func parseCodexLimitStatus(_ line: String) -> CodexLimitStatus? {
    guard let payload = codexPayload(line),
          payload["type"] as? String == "token_count"
    else { return nil }
    return codexLimitStatus(payload: payload)
}

/// Everything one `token_count` line carries. Both halves are optional and
/// independent: a limits-only event (payload.info null) still reports
/// rate_limits, and a turn can appear on a line with no rate_limits block.
public struct CodexLineParse: Equatable, Sendable {
    public let turn: CodexTurn?
    public let limitStatus: CodexLimitStatus?

    public init(turn: CodexTurn?, limitStatus: CodexLimitStatus?) {
        self.turn = turn
        self.limitStatus = limitStatus
    }
}

/// Parse one `token_count` line, decoding its JSON exactly once.
///
/// WHY this exists alongside the single-purpose helpers below: the scanner needs
/// the timestamp, the token counts and the rate limits from the same line, and
/// calling the three helpers decoded the same JSON three times. It also reads
/// rate_limits independently of the turn, so a limits-only event no longer
/// silently drops spend_control_reached / rate_limit_reached_type.
/// Returns nil for any line that is not a well-formed token_count event.
public func parseCodexLine(_ line: String, model: String? = nil) -> CodexLineParse? {
    guard let doc = codexDocument(line) else { return nil }
    return parseCodexLine(document: doc, model: model)
}

private func parseCodexLine(document doc: [String: Any], model: String?) -> CodexLineParse? {
    guard let payload = doc["payload"] as? [String: Any],
          payload["type"] as? String == "token_count"
    else { return nil }

    var turn: CodexTurn?
    if let info = payload["info"] as? [String: Any],
       let last = info["last_token_usage"] as? [String: Any],
       let ts = parseCodexTimestamp(doc["timestamp"] as? String) {
        func num(_ key: String) -> Int { (last[key] as? NSNumber)?.intValue ?? 0 }
        turn = CodexTurn(
            timestamp: ts,
            inputTokens: num("input_tokens"),
            cachedInputTokens: num("cached_input_tokens"),
            outputTokens: num("output_tokens"),
            totalTokens: num("total_tokens"),
            model: model)
    }
    return CodexLineParse(turn: turn, limitStatus: codexLimitStatus(payload: payload))
}

/// Shared JSON decode: one line → top-level doc.
private func codexDocument(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8),
          let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return doc
}

/// Shared JSON traversal: top-level doc → payload dict.
private func codexPayload(_ line: String) -> [String: Any]? {
    codexDocument(line)?["payload"] as? [String: Any]
}

private func codexLimitStatus(payload: [String: Any]) -> CodexLimitStatus? {
    guard let rl = payload["rate_limits"] as? [String: Any] else { return nil }

    let credits = rl["credits"] as? [String: Any]
    var primaryPercent: Int?
    if let primary = rl["primary"] as? [String: Any],
       let pct = primary["used_percent"] as? NSNumber {
        primaryPercent = Int(pct.doubleValue.rounded())
    }

    return CodexLimitStatus(
        planType: rl["plan_type"] as? String,
        hasCredits: credits?["has_credits"] as? Bool,
        creditBalance: (credits?["balance"] as? NSNumber)?.doubleValue,
        spendControlReached: rl["spend_control_reached"] as? Bool,
        rateLimitReachedType: rl["rate_limit_reached_type"] as? String,
        primaryUsedPercent: primaryPercent
    )
}

/// Formatter construction dominates scan cost (~0.6 ms per call, once per
/// token_count line), so both configurations are built once. ISO8601DateFormatter
/// is safe to share for parsing as long as formatOptions is never mutated after
/// setup — which is why there are two instances rather than one that is retuned.
nonisolated(unsafe) private let codexISO8601WithFraction: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

nonisolated(unsafe) private let codexISO8601Plain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

/// Codex timestamps are ISO 8601 with milliseconds ("2026-08-26T19:34:20.829Z").
///
/// WHY not parseResetDate: that helper strips fractional seconds because the
/// claude.ai API emits 6-digit fractions ISO8601DateFormatter mishandles; Codex
/// emits 3-digit fractions that .withFractionalSeconds parses fine, and we want
/// millisecond precision preserved for ordering turns within a session.
public func parseCodexTimestamp(_ iso: String?) -> Date? {
    guard let iso else { return nil }
    // Fallback covers lines written without fractional seconds.
    return codexISO8601WithFraction.date(from: iso) ?? codexISO8601Plain.date(from: iso)
}

// MARK: - Aggregation

/// Aggregate turns (grouped per session file) into today / rolling-7-day /
/// rolling-30-day / month-to-date totals with API-equivalent dollar estimates.
///
/// - Parameter turnsBySession: turns keyed by session file path (key only used to
///   count distinct sessions active today).
/// - Parameter limitStatus: newest plan/limit flags the scanner saw; passed through.
/// - Parameter now: injected for testability.
/// - Parameter calendar: injected for testability; callers use .current so "today"
///   follows the user's local midnight.
public func aggregateCodexUsage(
    turnsBySession: [String: [CodexTurn]],
    limitStatus: CodexLimitStatus? = nil,
    now: Date = Date(),
    calendar: Calendar = .current
) -> CodexSummary {
    let startOfToday = calendar.startOfDay(for: now)
    guard let weekStart = calendar.date(byAdding: .day, value: -6, to: startOfToday),
          let monthWindowStart = calendar.date(byAdding: .day, value: -29, to: startOfToday),
          let monthStart = calendar.date(
              from: calendar.dateComponents([.year, .month], from: now))
    else {
        return .empty
    }

    var todayTotal = 0, todayOutput = 0
    var weekTotal = 0, weekOutput = 0
    var window30Total = 0, mtdTotal = 0
    var todayCost = 0.0, weekCost = 0.0, window30Cost = 0.0, mtdCost = 0.0
    var perModelTokens: [String: Int] = [:]
    var perModelCost: [String: Double] = [:]
    var sessionsToday = 0
    var lastActivity: Date?

    for (_, turns) in turnsBySession {
        var sessionActiveToday = false
        for t in turns {
            // WHY after the guard: a clock-skewed or mis-stamped future line
            // would otherwise report recent activity while every window shows
            // zero usage, making the "no activity" row untrustworthy.
            guard t.timestamp <= now else { continue }
            if let la = lastActivity {
                if t.timestamp > la { lastActivity = t.timestamp }
            } else {
                lastActivity = t.timestamp
            }
            let cost = costOfCodexTurn(t)
            if t.timestamp >= monthWindowStart {
                window30Total += t.totalTokens
                window30Cost += cost
            }
            if t.timestamp >= monthStart {
                mtdTotal += t.totalTokens
                mtdCost += cost
            }
            if t.timestamp >= weekStart {
                weekTotal += t.totalTokens
                weekOutput += t.outputTokens
                weekCost += cost
                let modelKey = t.model ?? "unknown"
                perModelTokens[modelKey, default: 0] += t.totalTokens
                perModelCost[modelKey, default: 0] += cost
            }
            if t.timestamp >= startOfToday {
                todayTotal += t.totalTokens
                todayOutput += t.outputTokens
                todayCost += cost
                sessionActiveToday = true
            }
        }
        if sessionActiveToday { sessionsToday += 1 }
    }

    let perModel = perModelTokens.keys.map { model in
        CodexModelUsage(model: model,
                        totalTokens: perModelTokens[model] ?? 0,
                        cost: perModelCost[model] ?? 0)
    }.sorted { $0.cost > $1.cost }

    return CodexSummary(
        todayTotal: todayTotal, todayOutput: todayOutput, todayCost: todayCost,
        last7DaysTotal: weekTotal, last7DaysOutput: weekOutput, last7DaysCost: weekCost,
        last30DaysTotal: window30Total, last30DaysCost: window30Cost,
        monthToDateTotal: mtdTotal, monthToDateCost: mtdCost,
        perModel: perModel, sessionsToday: sessionsToday,
        lastActivity: lastActivity, limitStatus: limitStatus)
}

// MARK: - Token count formatting

/// Compact token count for the menu bar: 950 → "950", 12_345 → "12.3K",
/// 3_456_789 → "3.5M", 1_234_567_890 → "1.2B". One decimal, trailing ".0" dropped.
public func formatTokens(_ n: Int) -> String {
    let v = Double(n)
    func scaled(_ divisor: Double, _ suffix: String) -> String {
        let s = v / divisor
        // One decimal below 100 of a unit, whole numbers above ("99.5K" but "123K").
        let str = s < 100 ? String(format: "%.1f", s) : String(format: "%.0f", s)
        let trimmed = str.hasSuffix(".0") ? String(str.dropLast(2)) : str
        return trimmed + suffix
    }
    switch n {
    case ..<1_000:         return "\(n)"
    case ..<1_000_000:     return scaled(1_000, "K")
    case ..<1_000_000_000: return scaled(1_000_000, "M")
    default:               return scaled(1_000_000_000, "B")
    }
}

/// Full-precision grouped count for dropdown rows: 3456789 → "3,456,789".
///
/// Locale is injected for the same reason as the reset-time formatters: grouping
/// separators are locale-specific ("3.456.789" on de_DE), so tests pin a locale
/// while callers take the user's.
public func formatTokensLong(_ n: Int, locale: Locale = .autoupdatingCurrent) -> String {
    let fmt = NumberFormatter()
    fmt.numberStyle = .decimal
    fmt.locale = locale
    return fmt.string(from: NSNumber(value: n)) ?? "\(n)"
}
