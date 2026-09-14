/// ProviderVisibilityStore.swift — UserDefaults persistence for which providers
/// the menu bar shows. Same per-user domain/pattern as the other stores; the
/// "never hide both" rule lives in ClusageCore.ProviderVisibility so it stays
/// unit-testable.

import ClusageCore
import Foundation

enum ProviderVisibilityStore {
    static let claudeKey = "show_claude"
    /// Unchanged from the Codex-column-only release, so existing choices survive.
    static let codexKey = "codex_column_visible"

    /// Absent keys default to visible: a fresh install shows both providers
    /// (and Codex additionally auto-hides when no Codex install is detected).
    static func load() -> ProviderVisibility {
        ProviderVisibility.normalize(claude: bool(forKey: claudeKey), codex: bool(forKey: codexKey))
    }

    static func save(_ visibility: ProviderVisibility) {
        UserDefaults.standard.set(visibility.claude, forKey: claudeKey)
        UserDefaults.standard.set(visibility.codex, forKey: codexKey)
    }

    private static func bool(forKey key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
    }
}
