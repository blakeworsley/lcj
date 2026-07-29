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

if failures == 0 {
    print("OK — all tests passed")
    exit(0)
} else {
    print("\(failures) failure(s)")
    exit(1)
}
