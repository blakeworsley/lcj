/// ClodexTests — assertion-based test runner (no XCTest, runnable via `swift run`).
/// Pattern ported from mlg87/lcj clusage-menubar's ClusageTests.

import ClodexCore
import Foundation

var failures = 0

@MainActor
func expect(_ condition: Bool, _ label: String) {
    if condition {
        print("  ✓ \(label)")
    } else {
        print("  ✗ FAIL: \(label)")
        failures += 1
    }
}

@MainActor
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    if actual == expected {
        print("  ✓ \(label)")
    } else {
        print("  ✗ FAIL: \(label) — got \(actual), expected \(expected)")
        failures += 1
    }
}

// MARK: - Codex token_count line parsing

print("parseCodexTokenCountLine:")

let realLine = """
{"timestamp":"2026-08-26T19:34:25.107Z","ordinal":23,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":65477,"cached_input_tokens":46592,"cache_write_input_tokens":0,"output_tokens":317,"reasoning_output_tokens":64,"total_tokens":65794},"last_token_usage":{"input_tokens":33183,"cached_input_tokens":31488,"cache_write_input_tokens":0,"output_tokens":118,"reasoning_output_tokens":18,"total_tokens":33301},"model_context_window":258400},"rate_limits":{"limit_id":"codex","primary":null,"secondary":null}}}
"""
if let turn = parseCodexTokenCountLine(realLine) {
    expectEqual(turn.inputTokens, 33183, "input from last_token_usage (per-turn delta, not cumulative)")
    expectEqual(turn.cachedInputTokens, 31488, "cached input")
    expectEqual(turn.outputTokens, 118, "output")
    expectEqual(turn.totalTokens, 33301, "total")
    let cal = Calendar(identifier: .gregorian)
    var utc = cal
    utc.timeZone = TimeZone(identifier: "UTC")!
    expectEqual(utc.component(.hour, from: turn.timestamp), 19, "timestamp parsed with fractional seconds")
} else {
    expect(false, "real token_count line parses")
}

expect(parseCodexTokenCountLine("{\"type\":\"session_meta\",\"payload\":{}}") == nil,
       "non-token_count line returns nil")
expect(parseCodexTokenCountLine("{not json") == nil, "malformed JSON returns nil")
expect(parseCodexTokenCountLine(
    "{\"timestamp\":\"2026-08-26T19:34:25.107Z\",\"payload\":{\"type\":\"token_count\",\"info\":null}}") == nil,
       "token_count with null info returns nil")

let noFraction = """
{"timestamp":"2026-08-26T19:34:25Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"total_tokens":15}}}}
"""
expect(parseCodexTokenCountLine(noFraction)?.totalTokens == 15,
       "timestamp without fractional seconds still parses")

// MARK: - Aggregation

print("aggregateCodexUsage:")

var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "America/Denver")!
// Fixed "now": 2026-08-26 14:00 local.
let now = cal.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 14))!

@MainActor
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
expectEqual(summary.todayTotal, 3000, "today sums both turns of session a")
expectEqual(summary.todayOutput, 300, "today output")
expectEqual(summary.last7DaysTotal, 8700, "7-day window includes day-6, excludes day-7")
expectEqual(summary.last7DaysOutput, 870, "7-day output")
expectEqual(summary.last30DaysTotal, 18810, "30-day window adds day-7 and day-27, excludes day-40")
// now = Aug 26 → month starts Aug 1: excludes day-27 (Jul 30) but includes day-7 (Aug 19).
expectEqual(summary.monthToDateTotal, 18699, "month-to-date starts at calendar month start")
expectEqual(summary.sessionsToday, 1, "only session a active today")
expect(summary.lastActivity == sessions["a.jsonl"]![1].timestamp, "lastActivity is newest turn")

let empty = aggregateCodexUsage(turnsBySession: [:], now: now, calendar: cal)
expectEqual(empty.todayTotal, 0, "empty input → zero totals")
expect(empty.lastActivity == nil, "empty input → nil lastActivity")

print("budget barometer:")

expectEqual(budgetBand(monthCost: 79, budget: 100), Band.ok, "under budget → green")
expectEqual(budgetBand(monthCost: 100, budget: 100), Band.ok, "at budget → green")
expectEqual(budgetBand(monthCost: 150, budget: 100), Band.warn, "1-2x budget → yellow")
expectEqual(budgetBand(monthCost: 201, budget: 100), Band.critical, "over 2x budget → red")
expectEqual(budgetBand(monthCost: 999, budget: 0), Band.ok, "zero budget never alarms")
expectEqual(budgetFillPercent(monthCost: 79, budget: 100), 79, "fill percent = cost/budget")
expectEqual(budgetFillPercent(monthCost: 250, budget: 100), 100, "fill capped at 100")

// MARK: - Model attribution + limit status parsing

print("parseCodexModelLine / parseCodexLimitStatus:")

let turnContextLine = """
{"timestamp":"2026-08-26T19:50:02.480Z","type":"turn_context","payload":{"turn_id":"x","cwd":"/tmp","model":"gpt-5.6-luna","approval_policy":"never"}}
"""
expectEqual(parseCodexModelLine(turnContextLine) ?? "nil", "gpt-5.6-luna", "model from turn_context")
expect(parseCodexModelLine(realLine) == nil, "token_count line yields no model")

let sessionMetaLine = """
{"timestamp":"2026-08-26T09:26:33.000Z","type":"session_meta","payload":{"session_id":"x","base_instructions":{"text":"...","provenance":{"model":"gpt-5.6-luna"}}}}
"""
expectEqual(parseCodexModelLine(sessionMetaLine) ?? "nil", "gpt-5.6-luna",
            "model from session_meta base_instructions.provenance (ambient sessions)")

if let limit = parseCodexLimitStatus("""
{"timestamp":"2026-08-26T19:34:25.107Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":1}},"rate_limits":{"limit_id":"codex","primary":null,"secondary":null,"credits":{"has_credits":true,"unlimited":false,"balance":null},"spend_control_reached":null,"plan_type":"business","rate_limit_reached_type":null}}}
""") {
    expectEqual(limit.planType ?? "nil", "business", "plan type parsed")
    expectEqual(limit.hasCredits, true, "has_credits parsed")
    expect(limit.creditBalance == nil, "null balance stays nil")
    expect(!limit.isLimited, "healthy status is not limited")
} else {
    expect(false, "limit status parses from real-shaped rate_limits")
}

if let limited = parseCodexLimitStatus("""
{"timestamp":"2026-08-26T19:34:25.107Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"credits":{"has_credits":false},"spend_control_reached":true,"rate_limit_reached_type":"credits_exhausted","primary":{"used_percent":97.6}}}}
""") {
    expect(limited.isLimited, "spend control / exhausted credits flag as limited")
    expectEqual(limited.primaryUsedPercent, 98, "primary used_percent rounded")
} else {
    expect(false, "limited status parses")
}

// MARK: - Pricing / cost

print("pricing + costOfTurn:")

expectEqual(pricing(forModel: "gpt-5.6-luna").output, 1.20, "exact table hit")
expectEqual(pricing(forModel: "gpt-5.6-luna-2026-09-01").output, 1.20, "prefix match on dated variant")
expectEqual(pricing(forModel: "codex-auto-review"), fallbackPricing, "unknown model → fallback")
expectEqual(pricing(forModel: nil), fallbackPricing, "nil model → fallback")

// 1M uncached input + 1M cached + 1M output on luna: 0.20 + 0.02 + 1.20 = 1.42
let lunaTurn = CodexTurn(timestamp: now, inputTokens: 2_000_000, cachedInputTokens: 1_000_000,
                         outputTokens: 1_000_000, totalTokens: 3_000_000, model: "gpt-5.6-luna")
expect(abs(costOfTurn(lunaTurn) - 1.42) < 0.0001, "luna cost math (uncached/cached/output split)")

let solTurn = CodexTurn(timestamp: now, inputTokens: 500_000, cachedInputTokens: 0,
                        outputTokens: 100_000, totalTokens: 600_000, model: "gpt-5.6-sol")
expect(abs(costOfTurn(solTurn) - 4.0) < 0.0001, "sol cost math (0.5M×$4 + 0.1M×$20 = $4)")

expectEqual(pricing(forModel: "gpt-5.4-mini").output, 4.50, "gpt-5.4-mini in table")
let degenTurn = CodexTurn(timestamp: now, inputTokens: 0, cachedInputTokens: 0,
                          outputTokens: 0, totalTokens: 1_000_000, model: "gpt-5.6-luna")
expect(abs(costOfTurn(degenTurn) - 0.20) < 0.0001,
       "component-less total priced at input rate (ambient sessions)")

let costSessions: [String: [CodexTurn]] = ["s.jsonl": [lunaTurn, solTurn]]
let costSummary = aggregateCodexUsage(turnsBySession: costSessions, now: now, calendar: cal)
expect(abs(costSummary.todayCost - 5.42) < 0.0001, "aggregate today cost sums turns")
expectEqual(costSummary.perModel.count, 2, "per-model breakdown has both models")
expectEqual(costSummary.perModel.first?.model ?? "nil", "gpt-5.6-sol", "per-model sorted by cost desc")

print("formatCost:")

expectEqual(formatCost(0), "$0.00", "zero")
expectEqual(formatCost(3.456), "$3.46", "under $10 two decimals")
expectEqual(formatCost(12.34), "$12.3", "under $100 one decimal")
expectEqual(formatCost(123.4), "$123", "over $100 whole dollars")

// MARK: - Codex plan usage (ChatGPT spend control)

print("CodexPlanUsage.parse:")

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
    expectEqual(plan.usedPercent, 84, "used_percent parsed")
    expect(abs(plan.limitCredits - 4300) < 0.001, "string limit parsed to Double")
    expect(abs(plan.usedCredits - 3604.3499) < 0.001, "string used parsed")
    expect(abs(plan.remainingCredits - 695.6501) < 0.001, "string remaining parsed")
    expect(plan.resetsAt == Date(timeIntervalSince1970: 1788220801), "reset_at epoch parsed")
    expect(!plan.reached, "reached false")
} else {
    expect(false, "real wham/usage body parses")
}

expect(CodexPlanUsage.parse(
    "{\"plan_type\":\"business\",\"spend_control\":null}".data(using: .utf8)!) == nil,
    "null spend_control → nil (fall back to budget)")
expect(CodexPlanUsage.parse("{}".data(using: .utf8)!) == nil, "empty body → nil")

let numericBody = """
{"spend_control":{"reached":true,"individual_limit":{"limit":100,"used":100}}}
""".data(using: .utf8)!
if let capped = CodexPlanUsage.parse(numericBody) {
    expectEqual(capped.usedPercent, 100, "percent derived when used_percent absent")
    expect(capped.reached, "reached true propagates")
} else {
    expect(false, "numeric credits also parse")
}

print("menuBarShortDate:")

let resetDate = cal.date(from: DateComponents(year: 2026, month: 8, day: 31))!
expectEqual(menuBarShortDate(resetDate, locale: Locale(identifier: "en_US"),
                             timeZone: cal.timeZone), "8/31", "en_US month/day")
expectEqual(menuBarShortDate(nil), "–", "nil date dashes")

print("menuBarCountdown:")

let cdNow = now
func inSecs(_ s: TimeInterval) -> Date { cdNow.addingTimeInterval(s) }
expectEqual(menuBarCountdown(to: nil, from: cdNow), "–", "nil → dash")
expectEqual(menuBarCountdown(to: inSecs(30), from: cdNow), "<1m", "under a minute")
expectEqual(menuBarCountdown(to: inSecs(-100), from: cdNow), "<1m", "past date clamps")
expectEqual(menuBarCountdown(to: inSecs(38 * 60), from: cdNow), "38m", "minutes only")
expectEqual(menuBarCountdown(to: inSecs(2 * 3600 + 14 * 60), from: cdNow), "2h14m", "hours + minutes")
expectEqual(menuBarCountdown(to: inSecs(3 * 3600), from: cdNow), "3h", "whole hours drop minutes")
expectEqual(menuBarCountdown(to: inSecs(4 * 86400 + 9 * 3600 + 30 * 60), from: cdNow), "4d9h",
            "days + hours, minutes dropped")
expectEqual(menuBarCountdown(to: inSecs(5 * 86400 + 20 * 60), from: cdNow), "5d",
            "whole days drop hours")

// MARK: - Claude pricing

print("claudePricing / costOfClaudeMessage:")

expectEqual(claudePricing(forModel: "claude-fable-5")?.output, 50, "fable table hit")
expectEqual(claudePricing(forModel: "claude-haiku-4-5-20251001")?.input, 1,
            "dated haiku resolves by prefix")
expectEqual(claudePricing(forModel: "claude-opus-4-8")?.input, 5,
            "opus-4-8 longest-prefix beats opus-5")
expect(claudePricing(forModel: "<synthetic>") == nil, "synthetic model is free")
expectEqual(claudePricing(forModel: "claude-future-9")?.output,
            claudeFallbackPricing.output, "unknown model → fallback")

// Fable 5: 1M input=10 + 1M 5m write=12.5 + 1M 1h write=20 + 1M read=1 + 1M out=50
let fullCost = costOfClaudeMessage(model: "claude-fable-5",
                                   input: 1_000_000, cacheWrite5m: 1_000_000,
                                   cacheWrite1h: 1_000_000, cacheRead: 1_000_000,
                                   output: 1_000_000)
expect(abs(fullCost - 93.5) < 0.0001, "fable cost math across all buckets")
expectEqual(costOfClaudeMessage(model: "<synthetic>", input: 1_000_000,
                                cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0,
                                output: 1_000_000), 0, "synthetic costs zero")

// MARK: - Cost history buckets

print("CostHistory:")

let histNow = cal.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 14, minute: 30))!
expectEqual(costHistoryDayKey(histNow, calendar: cal), "2026-08-26", "day key format")
expectEqual(costHistoryHourKey(histNow, calendar: cal), "2026-08-26 14", "hour key format")

let days7 = dayKeys(last: 7, endingAt: histNow, calendar: cal)
expectEqual(days7.count, 7, "seven day keys")
expectEqual(days7.first ?? "nil", "2026-08-20", "oldest day first")
expectEqual(days7.last ?? "nil", "2026-08-26", "today last")

let hours12 = hourKeys(last: 12, endingAt: histNow, calendar: cal)
expectEqual(hours12.count, 12, "twelve hour keys")
expectEqual(hours12.last ?? "nil", "2026-08-26 14", "current hour last")
expectEqual(hours12.first ?? "nil", "2026-08-26 03", "oldest hour crosses correctly")

var h1 = CostHistory(dailyCost: ["2026-08-26": 5.0], hourlyCost: [:])
h1.merge(CostHistory(dailyCost: ["2026-08-26": 2.0, "2026-08-25": 1.0], hourlyCost: [:]))
expectEqual(h1.dailyCost["2026-08-26"], 7.0, "merge sums shared buckets")
expectEqual(h1.total(days: 7, endingAt: histNow, calendar: cal), 8.0, "windowed total")
expectEqual(h1.total(days: 1, endingAt: histNow, calendar: cal), 7.0, "today-only total")
expectEqual(historySeries(h1.dailyCost, keys: days7),
            [0, 0, 0, 0, 0, 1.0, 7.0], "series fills missing buckets with zero")

// MARK: - Token formatting

print("formatTokens:")

expectEqual(formatTokens(0), "0", "zero")
expectEqual(formatTokens(950), "950", "sub-thousand stays raw")
expectEqual(formatTokens(1_500), "1.5K", "thousands one decimal")
expectEqual(formatTokens(12_345), "12.3K", "tens of thousands")
expectEqual(formatTokens(123_456), "123K", "hundreds of thousands drop decimal")
expectEqual(formatTokens(3_456_789), "3.5M", "millions")
expectEqual(formatTokens(21_000_000), "21M", "trailing .0 dropped")
expectEqual(formatTokens(1_234_567_890), "1.2B", "billions")

// MARK: - Claude snapshot parsing (regression on the ported code)

print("UsageSnapshot.parse:")

let claudeBody = """
{"limits":[
  {"kind":"session","percent":42.4,"resets_at":"2026-08-26T21:00:00.156578+00:00"},
  {"kind":"weekly_all","percent":17,"resets_at":"2026-08-28T02:00:00+00:00"},
  {"kind":"weekly_scoped","percent":90.2,"scope":{"model":{"display_name":"Fable"}}}
]}
""".data(using: .utf8)!
if let snap = UsageSnapshot.parse(claudeBody) {
    expectEqual(snap.session?.percent, 42, "session percent rounded")
    expectEqual(snap.weeklyAll?.percent, 17, "weekly_all percent")
    expectEqual(snap.weeklyScoped?.label, "FABLE", "scoped label uppercased")
    expectEqual(snap.weeklyScoped?.percent, 90, "scoped percent rounded")
    expect(snap.session?.resetsAt != nil, "fractional-second resets_at parses")
} else {
    expect(false, "claude limits[] body parses")
}
expect(UsageSnapshot.parse("{}".data(using: .utf8)!) == nil, "empty body is bad_shape")

// The api.anthropic.com/api/oauth/usage response (Claude Code token path)
// carries the same limits[] shape plus extra null-heavy fields — must parse
// identically to the claude.ai cookie endpoint's response.
let oauthBody = """
{"five_hour":{"utilization":33.0,"resets_at":"2026-08-28T19:10:00.487027+00:00","limit_dollars":null},
 "seven_day":{"utilization":48.0,"resets_at":"2026-08-31T20:00:00.487048+00:00"},
 "seven_day_opus":null,"extra_usage":{"is_enabled":true,"monthly_limit":0},
 "limits":[
   {"kind":"session","group":"session","percent":33,"severity":"normal","resets_at":"2026-08-28T19:10:00.487027+00:00","scope":null,"is_active":false},
   {"kind":"weekly_all","group":"weekly","percent":48,"severity":"normal","resets_at":"2026-08-31T20:00:00.487048+00:00","scope":null,"is_active":false},
   {"kind":"weekly_scoped","group":"weekly","percent":49,"severity":"normal","resets_at":"2026-08-31T20:00:00.487277+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":true}],
 "spend":{"used":{"amount_minor":0},"percent":0}}
""".data(using: .utf8)!
if let snap = UsageSnapshot.parse(oauthBody) {
    expectEqual(snap.session?.percent ?? -1, 33, "oauth body: session percent")
    expectEqual(snap.weeklyAll?.percent ?? -1, 48, "oauth body: weekly_all percent")
    expectEqual(snap.weeklyScoped?.label ?? "nil", "FABLE", "oauth body: scoped label")
    expect(snap.session?.resetsAt != nil, "oauth body: session resets_at parsed")
} else {
    expect(false, "oauth usage body parses")
}

// MARK: - Cookie helpers (regression on the ported code)

print("cookie helpers:")

expectEqual(sanitizeCookie("Cookie: a=b; lastActiveOrg=xyz"), "a=b; lastActiveOrg=xyz",
            "leading Cookie: label stripped")
expectEqual(orgId(fromCookie: "a=b; lastActiveOrg=1234-abcd; c=d") ?? "nil", "1234-abcd",
            "orgId extracted")
expect(orgId(fromCookie: "a=b; c=d") == nil, "orgId nil when absent")

// MARK: - Result

if failures > 0 {
    print("\n\(failures) FAILURE(S)")
    exit(1)
}
print("\nAll tests passed.")
