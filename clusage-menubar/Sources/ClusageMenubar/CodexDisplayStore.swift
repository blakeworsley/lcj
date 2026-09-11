/// CodexDisplayStore.swift — UserDefaults-backed choices for the Codex menu bar
/// column: whether it is shown at all, and whether its values are estimated
/// dollars (default) or raw token counts. Same per-user-domain rationale as
/// CookieStore / RefreshIntervalStore.

import Foundation

enum CodexDisplayStore {
    static let visibleKey = "codex_column_visible"
    static let dollarsKey = "codex_menubar_shows_dollars"

    /// Defaults to visible. Note this is only the user's preference — the column
    /// is additionally auto-hidden when no Codex install is detected, so
    /// Claude-only users never see it (see StatusBarView.showsCodexColumn).
    static func isColumnVisible() -> Bool {
        if UserDefaults.standard.object(forKey: visibleKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: visibleKey)
    }

    static func save(columnVisible: Bool) {
        UserDefaults.standard.set(columnVisible, forKey: visibleKey)
    }

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
