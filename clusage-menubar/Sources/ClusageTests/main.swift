/// ClusageTests/main.swift — assertion-based test runner.
///
/// WHY not XCTest/swift-testing: both require the full Xcode toolchain; CLT-only
/// Swift installations don't provide `import XCTest` or `import Testing`. A plain
/// executable target that exit(1)s on failure integrates cleanly with `make test`
/// and CI without any framework dependency.

import ClusageCore
import Foundation

// MARK: - Test harness

// nonisolated(unsafe): top-level vars in main.swift are @MainActor in Swift 6;
// test helpers are nonisolated. Safe here — test runner is single-threaded.
nonisolated(unsafe) var failures = 0

func expect(_ cond: Bool, _ msg: String, file: String = #file, line: Int = #line) {
    if !cond {
        failures += 1
        print("FAIL [\(URL(fileURLWithPath: file).lastPathComponent):\(line)]: \(msg)")
    }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String, file: String = #file, line: Int = #line) {
    if a != b {
        failures += 1
        print("FAIL [\(URL(fileURLWithPath: file).lastPathComponent):\(line)]: \(msg) — got \(a), expected \(b)")
    }
}

// MARK: - Fixtures

/// Full live API response captured 2026-07-10 from the claude.ai org-usage endpoint
/// (GET /api/organizations/{orgId}/usage). Response shape matches the previous internal
/// endpoint — UsageSnapshot.parse works unchanged (verified against ClaudeUsageBar's
/// parser, 2026-07-10). This fixture pins the real shape so parse changes break visibly.
let fullLiveFixture = """
{
  "five_hour": {"utilization": 9.0, "resets_at": "2026-07-11T02:00:00.156578+00:00"},
  "seven_day": {"utilization": 12.0, "resets_at": "2026-07-14T19:00:00.156597+00:00"},
  "seven_day_opus": null,
  "limits": [
    {"kind": "session",       "group": "session", "percent": 9,  "severity": "normal", "resets_at": "2026-07-11T02:00:00.156578+00:00", "scope": null, "is_active": false},
    {"kind": "weekly_all",    "group": "weekly",  "percent": 12, "severity": "normal", "resets_at": "2026-07-14T19:00:00.156597+00:00", "scope": null, "is_active": true},
    {"kind": "weekly_scoped", "group": "weekly",  "percent": 5,  "severity": "normal", "resets_at": "2026-07-14T19:00:00.156863+00:00", "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}, "is_active": false}
  ]
}
"""

/// Fixture without `limits` but with five_hour / seven_day (fallback path).
let fallbackFixture = """
{
  "five_hour": {"utilization": 42.0, "resets_at": "2026-07-11T02:00:00+00:00"},
  "seven_day": {"utilization": 78.0, "resets_at": "2026-07-14T19:00:00+00:00"}
}
"""


// MARK: - Tests: UsageSnapshot.parse

func testFullLiveFixture() {
    let data = fullLiveFixture.data(using: .utf8)!
    let snap = UsageSnapshot.parse(data)
    expect(snap != nil, "Full live fixture: parse returned nil")
    guard let snap else { return }

    // session
    expect(snap.session != nil, "Full fixture: session should be non-nil")
    expectEqual(snap.session?.percent, 9, "Full fixture: session percent")
    expectEqual(snap.session?.label, "5H", "Full fixture: session label")
    expect(snap.session?.resetsAt != nil, "Full fixture: session resetsAt non-nil")

    // weeklyScoped
    expect(snap.weeklyScoped != nil, "Full fixture: weeklyScoped should be non-nil")
    expectEqual(snap.weeklyScoped?.percent, 5, "Full fixture: weeklyScoped percent")
    expectEqual(snap.weeklyScoped?.label, "FABLE", "Full fixture: weeklyScoped label (uppercased)")
    expect(snap.weeklyScoped?.resetsAt != nil, "Full fixture: weeklyScoped resetsAt non-nil")

    // weeklyAll
    expect(snap.weeklyAll != nil, "Full fixture: weeklyAll should be non-nil")
    expectEqual(snap.weeklyAll?.percent, 12, "Full fixture: weeklyAll percent")
    expectEqual(snap.weeklyAll?.label, "WEEK", "Full fixture: weeklyAll label")
    expect(snap.weeklyAll?.resetsAt != nil, "Full fixture: weeklyAll resetsAt non-nil")
}

func testParseResetDate() {
    // The 6-digit fractional-second string from the live fixture.
    let iso = "2026-07-11T02:00:00.156578+00:00"
    let date = parseResetDate(iso)
    expect(date != nil, "parseResetDate: returned nil for live fixture string")
    // Verify epoch — 2026-07-11T02:00:00Z = 1783735200
    // (= 2026-01-01 1767225600 + 191*86400 + 7200; 1752199200 is 2025-07-11, one year early)
    if let d = date {
        let expected = Date(timeIntervalSince1970: 1783735200)
        expect(abs(d.timeIntervalSince(expected)) < 1, "parseResetDate: epoch mismatch — got \(d.timeIntervalSince1970), expected 1783735200")
    }
}

func testFallbackFixture() {
    let data = fallbackFixture.data(using: .utf8)!
    let snap = UsageSnapshot.parse(data)
    expect(snap != nil, "Fallback fixture: parse returned nil")
    guard let snap else { return }
    expectEqual(snap.session?.percent, 42, "Fallback: session percent")
    expectEqual(snap.weeklyAll?.percent, 78, "Fallback: weeklyAll percent")
    expect(snap.weeklyScoped == nil, "Fallback: weeklyScoped should be nil")
}

func testBadShapeFixtures() {
    // Empty object — no five_hour, no limits
    let empty = "{}".data(using: .utf8)!
    expect(UsageSnapshot.parse(empty) == nil, "bad_shape: empty object should return nil")

    // Non-JSON garbage
    let garbage = "not json".data(using: .utf8)!
    expect(UsageSnapshot.parse(garbage) == nil, "bad_shape: garbage should return nil")

    // limits[] present but empty (and no fallback fields) → nil
    let emptyLimits = #"{"limits":[]}"#.data(using: .utf8)!
    expect(UsageSnapshot.parse(emptyLimits) == nil, "bad_shape: empty limits with no fallback → nil")
}

func testPercentClamping() {
    let fixture = #"""
    {"limits":[
      {"kind":"session","percent":250,"resets_at":null},
      {"kind":"weekly_all","percent":-5,"resets_at":null}
    ]}
    """#.data(using: .utf8)!
    let snap = UsageSnapshot.parse(fixture)
    expect(snap != nil, "Clamping: parse returned nil")
    expectEqual(snap?.session?.percent, 100, "Clamping: 250 should clamp to 100")
    expectEqual(snap?.weeklyAll?.percent, 0, "Clamping: -5 should clamp to 0")

    // Fractional percent (9.6 → 10)
    let fracFixture = #"""
    {"limits":[{"kind":"session","percent":9.6,"resets_at":null},{"kind":"weekly_all","percent":12,"resets_at":null}]}
    """#.data(using: .utf8)!
    let fracSnap = UsageSnapshot.parse(fracFixture)
    expectEqual(fracSnap?.session?.percent, 10, "Clamping: 9.6 should round to 10")
}

// MARK: - Tests: CookieAuth

func testSanitizeCookie() {
    // Passthrough — no label, no whitespace
    expectEqual(sanitizeCookie("a=1; b=2"), "a=1; b=2", "sanitizeCookie: passthrough")

    // Trim leading/trailing whitespace and newlines
    expectEqual(sanitizeCookie("  a=1\n"), "a=1", "sanitizeCookie: trims whitespace")

    // Strip "Cookie:" header label (with space) — case-insensitive
    expectEqual(sanitizeCookie("Cookie: a=1"), "a=1", "sanitizeCookie: strips 'Cookie: ' label")
    expectEqual(sanitizeCookie("cookie:a=1"), "a=1", "sanitizeCookie: strips 'cookie:' label case-insensitively")
}

func testOrgIdFromCookie() {
    // Mid-string with spaces after semicolons
    expectEqual(
        orgId(fromCookie: "anthropic-device-id=x; lastActiveOrg=1234-abcd; sessionKey=sk-ant"),
        "1234-abcd",
        "orgId: mid-string extraction"
    )

    // Absent key → nil
    expect(
        orgId(fromCookie: "sessionKey=sk-ant") == nil,
        "orgId: absent key should return nil"
    )

    // Empty value → nil
    expect(
        orgId(fromCookie: "lastActiveOrg=; sessionKey=x") == nil,
        "orgId: empty value should return nil"
    )
}

// MARK: - Tests: menuBarTime

func testMenuBarTime() {
    // nil → "–:–"
    expectEqual(menuBarTime(nil), "–:–", "menuBarTime(nil)")

    // Fixed date: 2026-07-13T01:00:00Z = 1783728000
    // In America/New_York (UTC-4 in July) that's 2026-07-12 21:00 local (9:00 PM)
    let date = Date(timeIntervalSince1970: 1783728000)
    let nyTZ = TimeZone(identifier: "America/New_York")!

    let en_US = Locale(identifier: "en_US")
    let usResult = menuBarTime(date, locale: en_US, timeZone: nyTZ)
    expect(usResult.contains("PM") || usResult.contains("pm"),
           "menuBarTime: en_US should produce 12h format containing PM, got: \(usResult)")

    let en_GB = Locale(identifier: "en_GB")
    let gbResult = menuBarTime(date, locale: en_GB, timeZone: nyTZ)
    expect(!gbResult.contains("AM") && !gbResult.contains("PM") && !gbResult.contains("am") && !gbResult.contains("pm"),
           "menuBarTime: en_GB should produce 24h format without AM/PM, got: \(gbResult)")
}

// MARK: - Tests: band

func testBand() {
    expectEqual(band(forPercent: 0),   .ok,       "band(0)=ok")
    expectEqual(band(forPercent: 69),  .ok,       "band(69)=ok")
    expectEqual(band(forPercent: 70),  .warn,     "band(70)=warn")
    expectEqual(band(forPercent: 89),  .warn,     "band(89)=warn")
    expectEqual(band(forPercent: 90),  .critical, "band(90)=critical")
    expectEqual(band(forPercent: 100), .critical, "band(100)=critical")
}

// MARK: - Tests: menuBarShortLabel

func testMenuBarShortLabel() {
    expectEqual(menuBarShortLabel("5H"), "5H", "5H stays 5H")
    expectEqual(menuBarShortLabel("WEEK"), "WK", "WEEK abbreviates to WK")
    expectEqual(menuBarShortLabel("FABLE"), "F",  "FABLE maps to F")
    expectEqual(menuBarShortLabel("op"), "OP", "short labels are uppercased")
    expectEqual(menuBarShortLabel("  "), "–", "blank label falls back to dash")
}

// MARK: - Tests: RefreshInterval

func testRefreshIntervalNormalize() {
    for m in RefreshInterval.allowedMinutes {
        expectEqual(RefreshInterval.normalize(m), m, "allowed value \(m) passes through")
    }
    expectEqual(RefreshInterval.normalize(0), 5, "absent (0) falls back to default")
    expectEqual(RefreshInterval.normalize(4), 5, "disallowed value falls back to default")
    expectEqual(RefreshInterval.normalize(-1), 5, "negative falls back to default")
    expectEqual(RefreshInterval.defaultMinutes, 5, "default stays the historical 5-min cadence")
}

// MARK: - Tests: Codex session-log parsing

/// Real `token_count` line captured 2026-08-26 from ~/.codex/sessions.
let codexTokenCountLine = """
{"timestamp":"2026-08-26T19:34:25.107Z","ordinal":23,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":65477,"cached_input_tokens":46592,"cache_write_input_tokens":0,"output_tokens":317,"reasoning_output_tokens":64,"total_tokens":65794},"last_token_usage":{"input_tokens":33183,"cached_input_tokens":31488,"cache_write_input_tokens":0,"output_tokens":118,"reasoning_output_tokens":18,"total_tokens":33301},"model_context_window":258400},"rate_limits":{"limit_id":"codex","primary":null,"secondary":null}}}
"""

func testParseCodexTokenCountLine() {
    guard let turn = parseCodexTokenCountLine(codexTokenCountLine) else {
        expect(false, "codex: real token_count line should parse")
        return
    }
    expectEqual(turn.inputTokens, 33183, "codex: input from last_token_usage (per-turn delta, not cumulative)")
    expectEqual(turn.cachedInputTokens, 31488, "codex: cached input")
    expectEqual(turn.outputTokens, 118, "codex: output")
    expectEqual(turn.totalTokens, 33301, "codex: total")
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    expectEqual(utc.component(.hour, from: turn.timestamp), 19, "codex: timestamp parsed with fractional seconds")

    expect(parseCodexTokenCountLine("{\"type\":\"session_meta\",\"payload\":{}}") == nil,
           "codex: non-token_count line returns nil")
    expect(parseCodexTokenCountLine("{not json") == nil, "codex: malformed JSON returns nil")
    expect(parseCodexTokenCountLine(
        "{\"timestamp\":\"2026-08-26T19:34:25.107Z\",\"payload\":{\"type\":\"token_count\",\"info\":null}}") == nil,
           "codex: token_count with null info returns nil")

    let noFraction = """
    {"timestamp":"2026-08-26T19:34:25Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"total_tokens":15}}}}
    """
    expectEqual(parseCodexTokenCountLine(noFraction)?.totalTokens, 15,
                "codex: timestamp without fractional seconds still parses")
}

func testParseCodexModelAndLimitLines() {
    let turnContextLine = """
    {"timestamp":"2026-08-26T19:50:02.480Z","type":"turn_context","payload":{"turn_id":"x","cwd":"/tmp","model":"gpt-5.6-luna","approval_policy":"never"}}
    """
    expectEqual(parseCodexModelLine(turnContextLine), "gpt-5.6-luna", "codex: model from turn_context")
    expect(parseCodexModelLine(codexTokenCountLine) == nil, "codex: token_count line yields no model")

    let sessionMetaLine = """
    {"timestamp":"2026-08-26T09:26:33.000Z","type":"session_meta","payload":{"session_id":"x","base_instructions":{"text":"...","provenance":{"model":"gpt-5.6-luna"}}}}
    """
    expectEqual(parseCodexModelLine(sessionMetaLine), "gpt-5.6-luna",
                "codex: model from session_meta base_instructions.provenance (ambient sessions)")

    let healthy = """
    {"timestamp":"2026-08-26T19:34:25.107Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":1}},"rate_limits":{"limit_id":"codex","primary":null,"secondary":null,"credits":{"has_credits":true,"unlimited":false,"balance":null},"spend_control_reached":null,"plan_type":"business","rate_limit_reached_type":null}}}
    """
    if let limit = parseCodexLimitStatus(healthy) {
        expectEqual(limit.planType, "business", "codex: plan type parsed")
        expectEqual(limit.hasCredits, true, "codex: has_credits parsed")
        expect(limit.creditBalance == nil, "codex: null balance stays nil")
        expect(!limit.isLimited, "codex: healthy status is not limited")
    } else {
        expect(false, "codex: limit status parses from real-shaped rate_limits")
    }

    let limited = """
    {"timestamp":"2026-08-26T19:34:25.107Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"credits":{"has_credits":false},"spend_control_reached":true,"rate_limit_reached_type":"credits_exhausted","primary":{"used_percent":97.6}}}}
    """
    if let status = parseCodexLimitStatus(limited) {
        expect(status.isLimited, "codex: spend control / exhausted credits flag as limited")
        expectEqual(status.primaryUsedPercent, 98, "codex: primary used_percent rounded")
    } else {
        expect(false, "codex: limited status parses")
    }
}

// MARK: - Tests: Codex aggregation + pricing

/// Fixed clock for the window tests: 2026-08-26 14:00 in America/Denver.
func codexTestCalendar() -> (cal: Calendar, now: Date) {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Denver")!
    let now = cal.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 14))!
    return (cal, now)
}

func testAggregateCodexUsage() {
    let (cal, now) = codexTestCalendar()
    func turn(daysAgo: Int, hour: Int, total: Int, output: Int) -> CodexTurn {
        let day = cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: now))!
        let ts = cal.date(byAdding: .hour, value: hour, to: day)!
        return CodexTurn(timestamp: ts, inputTokens: total - output, cachedInputTokens: 0,
                         outputTokens: output, totalTokens: total)
    }

    let sessions: [String: [CodexTurn]] = [
        "a.jsonl": [turn(daysAgo: 0, hour: 9, total: 1000, output: 100),
                    turn(daysAgo: 0, hour: 10, total: 2000, output: 200)],
        "b.jsonl": [turn(daysAgo: 3, hour: 12, total: 5000, output: 500)],
        "c.jsonl": [turn(daysAgo: 6, hour: 8, total: 700, output: 70)],    // oldest in-7d-window day
        "d.jsonl": [turn(daysAgo: 7, hour: 8, total: 9999, output: 999)],  // outside 7d, inside 30d
        "e.jsonl": [turn(daysAgo: 27, hour: 8, total: 111, output: 11)],   // Jul 30: inside 30d, before month start
        "f.jsonl": [turn(daysAgo: 40, hour: 8, total: 5555, output: 55)],  // outside every window
    ]

    let summary = aggregateCodexUsage(turnsBySession: sessions, now: now, calendar: cal)
    expectEqual(summary.todayTotal, 3000, "codex agg: today sums both turns of session a")
    expectEqual(summary.todayOutput, 300, "codex agg: today output")
    expectEqual(summary.last7DaysTotal, 8700, "codex agg: 7-day window includes day-6, excludes day-7")
    expectEqual(summary.last7DaysOutput, 870, "codex agg: 7-day output")
    expectEqual(summary.last30DaysTotal, 18810, "codex agg: 30-day window adds day-7 and day-27, excludes day-40")
    // now = Aug 26 → month starts Aug 1: excludes day-27 (Jul 30) but includes day-7 (Aug 19).
    expectEqual(summary.monthToDateTotal, 18699, "codex agg: month-to-date starts at calendar month start")
    expectEqual(summary.sessionsToday, 1, "codex agg: only session a active today")
    expectEqual(summary.lastActivity, sessions["a.jsonl"]![1].timestamp, "codex agg: lastActivity is newest turn")

    let empty = aggregateCodexUsage(turnsBySession: [:], now: now, calendar: cal)
    expectEqual(empty.todayTotal, 0, "codex agg: empty input → zero totals")
    expect(empty.lastActivity == nil, "codex agg: empty input → nil lastActivity")
}

func testCodexPricing() {
    let (cal, now) = codexTestCalendar()

    expectEqual(codexPricing(forModel: "gpt-5.6-luna").output, 1.20, "codex pricing: exact table hit")
    expectEqual(codexPricing(forModel: "gpt-5.6-luna-2026-09-01").output, 1.20, "codex pricing: prefix match on dated variant")
    expectEqual(codexPricing(forModel: "codex-auto-review"), codexFallbackPricing, "codex pricing: unknown model → fallback")
    expectEqual(codexPricing(forModel: nil), codexFallbackPricing, "codex pricing: nil model → fallback")
    expectEqual(codexPricing(forModel: "gpt-5.4-mini").output, 4.50, "codex pricing: gpt-5.4-mini in table")
    expectEqual(codexPricing(forModel: "gpt-6-astra").output, 50.00, "codex pricing: gpt-6-astra in table")

    // 1M uncached input + 1M cached + 1M output on luna: 0.20 + 0.02 + 1.20 = 1.42
    let lunaTurn = CodexTurn(timestamp: now, inputTokens: 2_000_000, cachedInputTokens: 1_000_000,
                             outputTokens: 1_000_000, totalTokens: 3_000_000, model: "gpt-5.6-luna")
    expect(abs(costOfCodexTurn(lunaTurn) - 1.42) < 0.0001, "codex cost: luna uncached/cached/output split")

    let solTurn = CodexTurn(timestamp: now, inputTokens: 500_000, cachedInputTokens: 0,
                            outputTokens: 100_000, totalTokens: 600_000, model: "gpt-5.6-sol")
    expect(abs(costOfCodexTurn(solTurn) - 4.0) < 0.0001, "codex cost: sol (0.5M×$4 + 0.1M×$20 = $4)")

    let degenTurn = CodexTurn(timestamp: now, inputTokens: 0, cachedInputTokens: 0,
                              outputTokens: 0, totalTokens: 1_000_000, model: "gpt-5.6-luna")
    expect(abs(costOfCodexTurn(degenTurn) - 0.20) < 0.0001,
           "codex cost: component-less total priced at input rate (ambient sessions)")

    let costSummary = aggregateCodexUsage(turnsBySession: ["s.jsonl": [lunaTurn, solTurn]], now: now, calendar: cal)
    expect(abs(costSummary.todayCost - 5.42) < 0.0001, "codex cost: aggregate today cost sums turns")
    expectEqual(costSummary.perModel.count, 2, "codex cost: per-model breakdown has both models")
    expectEqual(costSummary.perModel.first?.model, "gpt-5.6-sol", "codex cost: per-model sorted by cost desc")
}

func testBudgetBarometer() {
    expectEqual(budgetBand(monthCost: 79, budget: 100), .ok, "budget: under budget → green")
    expectEqual(budgetBand(monthCost: 100, budget: 100), .ok, "budget: at budget → green")
    expectEqual(budgetBand(monthCost: 150, budget: 100), .warn, "budget: 1-2x budget → yellow")
    expectEqual(budgetBand(monthCost: 201, budget: 100), .critical, "budget: over 2x budget → red")
    expectEqual(budgetBand(monthCost: 999, budget: 0), .ok, "budget: zero budget never alarms")
    expectEqual(budgetFillPercent(monthCost: 79, budget: 100), 79, "budget: fill percent = cost/budget")
    expectEqual(budgetFillPercent(monthCost: 250, budget: 100), 100, "budget: fill capped at 100")
}

func testFormatCostAndTokens() {
    expectEqual(formatCost(0), "$0.00", "formatCost: zero")
    expectEqual(formatCost(3.456), "$3.46", "formatCost: under $10 two decimals")
    expectEqual(formatCost(12.34), "$12.3", "formatCost: under $100 one decimal")
    expectEqual(formatCost(123.4), "$123", "formatCost: over $100 whole dollars")

    expectEqual(formatTokens(0), "0", "formatTokens: zero")
    expectEqual(formatTokens(950), "950", "formatTokens: sub-thousand stays raw")
    expectEqual(formatTokens(1_500), "1.5K", "formatTokens: thousands one decimal")
    expectEqual(formatTokens(12_345), "12.3K", "formatTokens: tens of thousands")
    expectEqual(formatTokens(123_456), "123K", "formatTokens: hundreds of thousands drop decimal")
    expectEqual(formatTokens(3_456_789), "3.5M", "formatTokens: millions")
    expectEqual(formatTokens(21_000_000), "21M", "formatTokens: trailing .0 dropped")
    expectEqual(formatTokens(1_234_567_890), "1.2B", "formatTokens: billions")
    expectEqual(formatTokensLong(3_456_789), "3,456,789", "formatTokensLong: grouped")
}

// MARK: - Tests: Codex plan usage (ChatGPT spend control)

func testCodexPlanUsageParse() {
    let whamBody = """
    {"user_id":"user-x","plan_type":"business","rate_limit":null,
     "credits":{"has_credits":true,"unlimited":false,"balance":null},
     "spend_control":{"reached":false,"individual_limit":{
       "source":"workspace_spend_controls",
       "limit":"4300","used":"3604.349905371666","remaining":"695.650094628334",
       "used_percent":84,"remaining_percent":16,
       "reset_after_seconds":380033,"reset_at":1788220801}}}
    """.data(using: .utf8)!
    if let plan = CodexPlanUsage.parse(whamBody) {
        expectEqual(plan.usedPercent, 84, "plan: used_percent parsed")
        expect(abs(plan.limitCredits - 4300) < 0.001, "plan: string limit parsed to Double")
        expect(abs(plan.usedCredits - 3604.3499) < 0.001, "plan: string used parsed")
        expect(abs(plan.remainingCredits - 695.6501) < 0.001, "plan: string remaining parsed")
        expectEqual(plan.resetsAt, Date(timeIntervalSince1970: 1788220801), "plan: reset_at epoch parsed")
        expect(!plan.reached, "plan: reached false")
    } else {
        expect(false, "plan: real wham/usage body parses")
    }

    expect(CodexPlanUsage.parse("{\"plan_type\":\"business\",\"spend_control\":null}".data(using: .utf8)!) == nil,
           "plan: null spend_control → nil (fall back to budget)")
    expect(CodexPlanUsage.parse("{}".data(using: .utf8)!) == nil, "plan: empty body → nil")

    let numericBody = """
    {"spend_control":{"reached":true,"individual_limit":{"limit":100,"used":100}}}
    """.data(using: .utf8)!
    if let capped = CodexPlanUsage.parse(numericBody) {
        expectEqual(capped.usedPercent, 100, "plan: percent derived when used_percent absent")
        expect(capped.reached, "plan: reached true propagates")
    } else {
        expect(false, "plan: numeric credits also parse")
    }
}

func testMenuBarShortDate() {
    let (cal, _) = codexTestCalendar()
    let resetDate = cal.date(from: DateComponents(year: 2026, month: 8, day: 31))!
    expectEqual(menuBarShortDate(resetDate, locale: Locale(identifier: "en_US"), timeZone: cal.timeZone),
                "8/31", "menuBarShortDate: en_US month/day")
    expectEqual(menuBarShortDate(nil), "–", "menuBarShortDate: nil date dashes")
}

// MARK: - Run all tests

print("Running ClusageTests…")
testFullLiveFixture()
testParseResetDate()
testFallbackFixture()
testBadShapeFixtures()
testPercentClamping()
testSanitizeCookie()
testOrgIdFromCookie()
testMenuBarTime()
testBand()
testMenuBarShortLabel()
testRefreshIntervalNormalize()
testParseCodexTokenCountLine()
testParseCodexModelAndLimitLines()
testAggregateCodexUsage()
testCodexPricing()
testBudgetBarometer()
testFormatCostAndTokens()
testCodexPlanUsageParse()
testMenuBarShortDate()

if failures == 0 {
    print("OK — all tests passed")
    exit(0)
} else {
    print("\(failures) failure(s)")
    exit(1)
}
