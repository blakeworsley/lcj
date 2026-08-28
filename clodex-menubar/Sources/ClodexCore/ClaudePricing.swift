/// ClaudePricing.swift — token → dollar estimation for Claude Code local logs.
///
/// Claude Code writes per-assistant-message usage into ~/.claude/projects
/// session files. For subscription users these are API-equivalent value
/// estimates (what the tokens would cost à la carte), mirroring the optional
/// ledger script (tools/ai_usage_snapshot.py — keep the two tables in sync).
///
/// Rates source: platform.claude.com/docs/en/about-claude/pricing
/// (checked 2026-08-26). $ per 1M tokens.

import Foundation

/// Dollars per 1M tokens for one Claude model family.
public struct ClaudeModelPricing: Equatable, Sendable {
    public let input: Double
    public let cacheWrite5m: Double
    public let cacheWrite1h: Double
    public let cacheRead: Double
    public let output: Double

    public init(input: Double, cacheWrite5m: Double, cacheWrite1h: Double,
                cacheRead: Double, output: Double) {
        self.input = input
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.output = output
    }
}

/// Keyed by model-id prefix; resolution picks the longest matching prefix so
/// "claude-opus-5" wins over "claude-opus-4" for dated variants of either.
public let claudePricingTable: [String: ClaudeModelPricing] = [
    "claude-fable-5":  ClaudeModelPricing(input: 10, cacheWrite5m: 12.50, cacheWrite1h: 20, cacheRead: 1.00, output: 50),
    "claude-mythos-5": ClaudeModelPricing(input: 10, cacheWrite5m: 12.50, cacheWrite1h: 20, cacheRead: 1.00, output: 50),
    "claude-opus-5":   ClaudeModelPricing(input: 5, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.50, output: 25),
    "claude-opus-4":   ClaudeModelPricing(input: 5, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.50, output: 25),
    "claude-sonnet-5": ClaudeModelPricing(input: 2, cacheWrite5m: 2.50, cacheWrite1h: 4, cacheRead: 0.20, output: 10),
    "claude-sonnet-4": ClaudeModelPricing(input: 3, cacheWrite5m: 3.75, cacheWrite1h: 6, cacheRead: 0.30, output: 15),
    "claude-haiku-4":  ClaudeModelPricing(input: 1, cacheWrite5m: 1.25, cacheWrite1h: 2, cacheRead: 0.10, output: 5),
]

public let claudeFallbackPricing = claudePricingTable["claude-opus-5"]!

/// Longest-prefix pricing resolution; synthetic placeholder rows cost nothing.
public func claudePricing(forModel model: String?) -> ClaudeModelPricing? {
    guard let model, !model.isEmpty else { return claudeFallbackPricing }
    if model == "<synthetic>" { return nil }
    var best: (prefix: String, pricing: ClaudeModelPricing)?
    for (prefix, p) in claudePricingTable where model.hasPrefix(prefix) {
        if best == nil || prefix.count > best!.prefix.count {
            best = (prefix, p)
        }
    }
    return best?.pricing ?? claudeFallbackPricing
}

/// Estimated dollar cost of one assistant message's usage block.
/// `cacheWrite5m`/`cacheWrite1h` come from usage.cache_creation when present;
/// callers with only the total should pass it all as 5m (the common case).
public func costOfClaudeMessage(model: String?, input: Int, cacheWrite5m: Int,
                                cacheWrite1h: Int, cacheRead: Int, output: Int) -> Double {
    guard let p = claudePricing(forModel: model) else { return 0 }
    return (Double(input) * p.input
            + Double(cacheWrite5m) * p.cacheWrite5m
            + Double(cacheWrite1h) * p.cacheWrite1h
            + Double(cacheRead) * p.cacheRead
            + Double(output) * p.output) / 1_000_000
}
