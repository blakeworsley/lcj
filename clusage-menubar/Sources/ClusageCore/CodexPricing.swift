/// CodexPricing.swift — token → dollar estimation for Codex usage.
///
/// Codex business/credit plans never report a balance or limit window to the
/// client (rate_limits.primary/secondary and credits.balance are null in every
/// session log), so the app estimates spend instead: tokens priced at OpenAI's
/// STANDARD API tier. Credit-plan internal rates may differ — treat the output
/// as an "API-equivalent" estimate, not a bill.
///
/// Rates source: developers.openai.com/api/docs/pricing (standard tier,
/// checked 2026-09-11). Update the table when prices move.
///
/// KNOWN GAPS, both of which under-report cost on heavy sessions:
///   - gpt-5.6-sol's $4.00/$20.00 is promotional through 2026-11-21; it reverts
///     after that date and this table will need the new rates.
///   - Requests over 272K input tokens reprice the whole request (2x input,
///     1.5x output) and that is not modelled here, so long agent sessions —
///     which resend full context every turn — read low.

import Foundation

// MARK: - Pricing model

/// Dollars per 1M tokens.
public struct CodexModelPricing: Equatable, Sendable {
    public let input: Double
    public let cachedInput: Double
    public let output: Double

    public init(input: Double, cachedInput: Double, output: Double) {
        self.input = input
        self.cachedInput = cachedInput
        self.output = output
    }
}

/// Standard-tier API prices for the models seen in Codex session logs.
public let codexPricingTable: [String: CodexModelPricing] = [
    "gpt-6-astra":   CodexModelPricing(input: 10.00, cachedInput: 1.00, output: 50.00),
    "gpt-5.6-sol":   CodexModelPricing(input: 4.00, cachedInput: 0.40, output: 20.00),
    "gpt-5.6-terra": CodexModelPricing(input: 2.00, cachedInput: 0.20, output: 12.00),
    "gpt-5.6-luna":  CodexModelPricing(input: 0.20, cachedInput: 0.02, output: 1.20),
    "gpt-5.4":       CodexModelPricing(input: 2.50, cachedInput: 0.25, output: 15.00),
    "gpt-5.4-mini":  CodexModelPricing(input: 0.75, cachedInput: 0.075, output: 4.50),
    "gpt-5.3-codex": CodexModelPricing(input: 1.75, cachedInput: 0.175, output: 14.00),
]

/// Applied to models with no table entry (e.g. "codex-auto-review", an internal
/// model with no public price). terra = the mid-tier rate: a deliberate
/// middle-of-the-road guess rather than best- or worst-case.
public let codexFallbackPricing = CodexModelPricing(input: 2.00, cachedInput: 0.20, output: 12.00)

/// Resolve pricing for a model name: exact match, then LONGEST prefix match
/// (handles dated/suffixed variants like "gpt-5.6-luna-2026-08-01"), then fallback.
///
/// WHY longest match rather than first match: "gpt-5.4-mini-2026-08-01" prefixes
/// both "gpt-5.4-mini" and "gpt-5.4", and Dictionary iteration order is
/// randomized per process — a first-match scan priced the same model at $0.75 or
/// $2.50 per 1M input depending on the launch.
public func codexPricing(forModel model: String?) -> CodexModelPricing {
    guard let model, !model.isEmpty else { return codexFallbackPricing }
    if let exact = codexPricingTable[model] { return exact }
    if let best = codexPricingTable.filter({ model.hasPrefix($0.key) })
        .max(by: { $0.key.count < $1.key.count }) {
        return best.value
    }
    return codexFallbackPricing
}

/// Estimated dollar cost of one turn. `input_tokens` includes the cached
/// portion, so the uncached remainder is billed at the full input rate and the
/// cached portion at the cached rate.
///
/// Ambient Codex Desktop sessions emit component-less lines (total_tokens set,
/// input/output zero); those totals are priced at the input rate — the
/// least-wrong single rate when the split is unknown.
public func costOfCodexTurn(_ t: CodexTurn) -> Double {
    let p = codexPricing(forModel: t.model)
    if t.inputTokens == 0 && t.outputTokens == 0 && t.totalTokens > 0 {
        return Double(t.totalTokens) * p.input / 1_000_000
    }
    let uncached = Double(max(0, t.inputTokens - t.cachedInputTokens))
    let cached = Double(t.cachedInputTokens)
    let output = Double(t.outputTokens)
    return (uncached * p.input + cached * p.cachedInput + output * p.output) / 1_000_000
}

// MARK: - Monthly budget barometer

/// Fallback framing when no real monthly limit is reported: ~$100/month of
/// Codex is normal; over 2× that is heavy.
/// green = at or under budget · yellow = up to 2× budget · red = beyond 2×.
///
/// WHY a separate band function: the Claude gauges use `band(forPercent:)`
/// (70/90 thresholds on a hard limit). A self-chosen budget is a soft target,
/// so it gets its own, gentler thresholds instead of alarming at 70%.
public func budgetBand(monthCost: Double, budget: Double) -> Band {
    guard budget > 0 else { return .ok }
    switch monthCost / budget {
    case ...1.0:  return .ok
    case ...2.0:  return .warn
    default:      return .critical
    }
}

/// Gauge fill for the budget bar: percent of budget spent, capped at 100
/// (the band color, not the fill, signals overshoot).
public func budgetFillPercent(monthCost: Double, budget: Double) -> Int {
    guard budget > 0 else { return 0 }
    return min(100, Int((monthCost / budget * 100).rounded()))
}

// MARK: - Cost formatting

/// Compact dollar string: "$0.42", "$3.42" (<10: 2 decimals), "$12.4" (<100: 1
/// decimal), "$123" (≥100: whole dollars).
public func formatCost(_ dollars: Double) -> String {
    switch dollars {
    case ..<10:  return String(format: "$%.2f", dollars)
    case ..<100: return String(format: "$%.1f", dollars)
    default:     return String(format: "$%.0f", dollars.rounded())
    }
}
