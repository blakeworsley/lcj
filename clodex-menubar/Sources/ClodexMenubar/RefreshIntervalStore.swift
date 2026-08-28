/// RefreshIntervalStore.swift — UserDefaults-backed persistence for the
/// auto-refresh interval. Same domain/pattern as CookieStore: per-user, so the
/// choice survives rebuilds and reinstalls. Validation lives in
/// ClodexCore.RefreshInterval so it stays unit-testable.

import ClodexCore
import Foundation

enum RefreshIntervalStore {
    static let defaultsKey = "refresh_interval_minutes"

    /// Always returns an allowed value: UserDefaults.integer yields 0 when
    /// the key is absent, and RefreshInterval.normalize maps 0 → default (5).
    static func load() -> Int {
        RefreshInterval.normalize(UserDefaults.standard.integer(forKey: defaultsKey))
    }

    static func save(_ minutes: Int) {
        UserDefaults.standard.set(RefreshInterval.normalize(minutes), forKey: defaultsKey)
    }
}
