/// CodexBudgetStore.swift — the monthly Codex spend barometer, in dollars.
///
/// Default framing: ~$100/month is normal usage; over $200/month is heavy.
/// The stored value is the green/yellow boundary; 2× it is the yellow/red
/// boundary (see ClodexCore.budgetBand).

import Foundation

enum CodexBudgetStore {
    static let defaultsKey = "codex_monthly_budget"
    static let defaultBudget = 100.0
    /// Dropdown choices.
    static let options: [Double] = [50, 100, 150, 200, 300]

    static func load() -> Double {
        let v = UserDefaults.standard.double(forKey: defaultsKey)
        return v > 0 ? v : defaultBudget
    }

    static func save(_ dollars: Double) {
        UserDefaults.standard.set(dollars, forKey: defaultsKey)
    }
}
