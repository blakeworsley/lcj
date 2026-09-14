/// CodexDisplayStore.swift — UserDefaults-backed choice of what the Codex
/// values show: estimated dollars (default) or raw token counts. Same
/// per-user-domain rationale as CookieStore / RefreshIntervalStore.
/// Whether the Codex block appears at all lives in ProviderVisibilityStore.

import Foundation

enum CodexDisplayStore {
    static let dollarsKey = "codex_menubar_shows_dollars"

    /// Defaults to dollars: the estimate is the number the token counts exist
    /// to approximate.
    static func showsDollars() -> Bool {
        if UserDefaults.standard.object(forKey: dollarsKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: dollarsKey)
    }

    static func save(showsDollars: Bool) {
        UserDefaults.standard.set(showsDollars, forKey: dollarsKey)
    }
}
