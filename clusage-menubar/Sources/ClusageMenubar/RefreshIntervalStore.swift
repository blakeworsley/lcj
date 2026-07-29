/// RefreshIntervalStore.swift — UserDefaults-backed persistence for the
/// auto-refresh interval.
///
/// WHY UserDefaults and this shape: same domain/pattern as CookieStore — the
/// com.mlg87.clusage-menubar domain is per-user (not per-signature), so the
/// choice survives rebuilds and reinstalls. Validation lives in
/// ClusageCore.RefreshInterval so it stays unit-testable.

import ClusageCore
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
