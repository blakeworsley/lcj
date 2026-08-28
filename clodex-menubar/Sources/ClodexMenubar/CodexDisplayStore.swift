/// CodexDisplayStore.swift — UserDefaults-backed choice of what the Codex menu
/// bar column shows: estimated dollars (default) or raw token counts.
/// Same per-user-domain rationale as CookieStore / RefreshIntervalStore.

import Foundation

enum CodexDisplayStore {
    static let defaultsKey = "codex_menubar_shows_dollars"

    /// Defaults to dollars: the estimate is the number the token counts exist
    /// to approximate.
    static func showsDollars() -> Bool {
        if UserDefaults.standard.object(forKey: defaultsKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static func save(showsDollars: Bool) {
        UserDefaults.standard.set(showsDollars, forKey: defaultsKey)
    }
}
